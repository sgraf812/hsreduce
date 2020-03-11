{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PatternSynonyms #-}

module Passes.RemoveUnused.Decls where

import Control.Monad.State.Strict
import qualified Data.Text as T
import qualified Data.Text.IO as TIO (writeFile)
import Debug.Trace
import HsSyn
import Ormolu.Parser.Pragma as OPP (Pragma (PragmaLanguage))
import Ormolu.Parser.Result as OPR (ParseResult, prExtensions, prParsedSource)
import Ormolu.Printer (printModule)
import Outputable (ppr, showSDocUnsafe)
import SrcLoc (GenLocated (..), Located (..), getLoc, noLoc, unLoc)
import Types
import Util

-- | run ghc with -Wunused-binds -ddump-json and delete decls that are mentioned there
reduce :: FilePath -> FilePath -> OPR.ParseResult -> IO OPR.ParseResult
reduce test sourceFile oldOrmolu = do
  putStrLn "\n***Removing unused declarations***"
  debugPrint $ "Size of old ormolu: " ++ (show . T.length $ printModule oldOrmolu)
  runGhc test sourceFile oldOrmolu Binds
    >>= \case
      Nothing -> return oldOrmolu
      Just unusedBindingNames -> do
        debugPrint $ "unused binding names: " ++ show unusedBindingNames
        let allDecls = hsmodDecls . unLoc . prParsedSource $ oldOrmolu
        ReduceState _ _ newOrmolu <- execStateT (traverse (removeUnusedDecl unusedBindingNames) allDecls) (ReduceState test sourceFile oldOrmolu)
        return newOrmolu

pattern FunDecl declLoc funId <- L declLoc (ValD _ (FunBind _ funId _ _ _))
pattern TypeSigDecl declLoc funIds sigWctype <- L declLoc (SigD _ (TypeSig _ funIds sigWctype))
pattern TypeSigDeclX declLoc funIds sigWctype = L declLoc (SigD NoExt (TypeSig NoExt funIds sigWctype))
pattern TypeClassDecl declLoc tyId tyVars tyFixity nd ctxt cType kindSig constructors derivs <-
  (L declLoc (TyClD _ (DataDecl _ tyId tyVars tyFixity (HsDataDefn _ nd ctxt cType kindSig constructors derivs))))

-- | remove:
-- - unused function bindings with their type signatures
-- - constructors from unused data types
-- - data types without constructors
removeUnusedDecl :: [BindingName] -> LHsDecl GhcPs -> StateT ReduceState IO ()
-- TODO: iwie ist das unschön, dass hier mehr gemacht wird, als nur die value decl zu löschen
removeUnusedDecl unusedBindingNames (FunDecl declLoc funId) = do
  ReduceState test sourceFile oldOrmolu <- get
  when (showSDocUnsafe (ppr $ unLoc funId) `elem` unusedBindingNames) $ do
    debugPrint $ "looking at function binding: " ++ (showSDocUnsafe . ppr . unLoc $ funId)
    let newOrmolu =
          changeDecls
            oldOrmolu
            ( map
                ( \iterDecl -> case iterDecl of
                    -- if a signature is defined for several IDs, the function ID should be removed from the list of identifiers
                    -- TODO: check if this is working properly
                    TypeSigDecl iterLoc funIds sigWctype ->
                      let newFunIds = filter ((`notElem` unusedBindingNames) . showSDocUnsafe . ppr . unLoc) funIds
                       in TypeSigDeclX iterLoc newFunIds sigWctype
                    _ -> iterDecl
                )
                . filter
                  ( \(L iterLoc iterDecl) ->
                      case iterDecl of
                        SigD _ (TypeSig _ [tyFunId] _) -> ((`notElem` unusedBindingNames) . showSDocUnsafe . ppr . unLoc) tyFunId
                        other -> iterLoc /= declLoc
                  )
            )
    testAndUpdateState newOrmolu
removeUnusedDecl unusedBindingNames (TypeClassDecl declLoc tyId tyVars tyFixity nd ctxt cType kindSig constructors derivs) = do
  oldOrmolu <- _ormolu <$> get
  let newConstructors = filter (constructorIsUsed unusedBindingNames) constructors
      newDecl =
        TyClD
          NoExt
          ( DataDecl
              NoExt
              tyId
              tyVars
              tyFixity
              (HsDataDefn NoExt nd ctxt cType kindSig newConstructors derivs)
          )
      newOrmolu =
        changeDecls
          oldOrmolu
          ( if null constructors
              then filter (\(L iterLoc _) -> iterLoc /= declLoc)
              else map (\(L iterLoc iterDecl) -> if iterLoc == declLoc then L declLoc newDecl else L iterLoc iterDecl)
          )
  testAndUpdateState newOrmolu
-- TODO: more fine granular handling of instance decls
removeUnusedDecl unusedBindingNames (L declLoc (InstD _ _)) = do
  oldOrmolu <- _ormolu <$> get
  let newOrmolu = changeDecls oldOrmolu (filter (\(L iterLoc _) -> iterLoc /= declLoc))
  testAndUpdateState newOrmolu
removeUnusedDecl unusedBindingNames (L declLoc (TyClD _ ClassDecl {})) = do
  ReduceState _ _ oldOrmolu <- get
  let newOrmolu = changeDecls oldOrmolu (filter (\(L iterLoc _) -> iterLoc /= declLoc))
  testAndUpdateState newOrmolu
removeUnusedDecl _ _ = return ()

pattern H98Decl rdrName <- L _ (ConDeclH98 _ (L _ rdrName) _ _ _ _ _)
pattern GADTDecl names <- L _ (ConDeclGADT _ names _ _ _ _ _ _)

constructorIsUsed :: [String] -> LConDecl GhcPs -> Bool
constructorIsUsed unusedBindingNames (H98Decl rdrName) = (showSDocUnsafe . ppr $ rdrName) `notElem` unusedBindingNames
constructorIsUsed unusedBindingNames (GADTDecl names) =
  let result = all (\(L _ rdrName) -> (showSDocUnsafe . ppr $ rdrName) `notElem` unusedBindingNames) names
   in traceShow (if not result then "constructor " ++ unwords (map (showSDocUnsafe . ppr) names) ++ "is used: " ++ show result else []) result