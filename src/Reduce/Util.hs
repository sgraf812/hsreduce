module Reduce.Util where

import Debug.Trace
import Control.Monad.State.Strict
import Data.Data
import Data.Aeson (decode)
import Data.ByteString.Lazy.Char8 (pack)
import Data.List (isPrefixOf)
import Data.Maybe
import qualified Data.Text.IO as TIO (writeFile)
import Ormolu.Parser.Pragma as OPP (Pragma (PragmaLanguage))
import Ormolu.Parser.Result as OPR (ParseResult, prExtensions, prParsedSource)
import Ormolu.Printer (printModule)
import System.Exit
import System.FilePath.Posix
import System.Process
import System.Timeout
import HsSyn
import SrcLoc
import Outputable

import Reduce.Types


tryRemoveEach :: Typeable a 
              => (t -> t -> Bool)
              -> ([t] -> a)
              -> Located a
              -> [t]
              -> ReduceM (Located a)
tryRemoveEach f constr e oldList =
  foldM (\iterE ld -> let newList = filter (f ld) oldList
                     in tryNewValue iterE (constr newList)) e oldList

oshow :: Outputable a => a -> String
oshow = showSDocUnsafe . ppr

lshow :: Outputable a => Located a -> String
lshow = showSDocUnsafe . ppr . unLoc

tryNewValue :: Typeable a => Located a -> a -> ReduceM (Located a)
tryNewValue oldDecl@(L loc _) newValue = do
  oldOrmolu <- _ormolu <$> get
  let oldModule = prParsedSource oldOrmolu
      newModule = everywhereT (mkT (overwriteAtLoc loc newValue)) oldModule
  testAndUpdateStateFlex oldDecl (L loc newValue) (oldOrmolu{ prParsedSource = newModule})

overwriteAtLoc :: SrcSpan   -- ^ loc:      location that should be updated
               -> a         -- ^ newValue: has to come before oldValue because we use it in a closure
               -> Located a -- ^ oldValue
               -> Located a
overwriteAtLoc loc newValue oldValue@(L oldLoc _)
  | loc == oldLoc = L loc newValue
  | otherwise     = oldValue

testAndUpdateState :: OPR.ParseResult -> ReduceM ()
testAndUpdateState = testAndUpdateStateFlex () ()

testAndUpdateStateFlex :: a -> a -> OPR.ParseResult -> ReduceM a
testAndUpdateStateFlex a b newOrmolu  = do
  sourceFile <- _sourceFile <$> get
  liftIO $ TIO.writeFile sourceFile . printModule $ newOrmolu
  runTest
    >>= \case
      Uninteresting -> return a
      Interesting -> do
        -- TODO: add information to change operation for better debugging messages
        liftIO $ putStr "+"
        modify $ \s -> s {_ormolu = newOrmolu}
        return b

-- | run the interestingness test on a timeout of 30 seconds
runTest :: ReduceM Interesting
runTest = do
  test <- _test <$> get
  let (dirName, testName) = splitFileName test
  -- TODO: make timout duration configurable
  liftIO $ timeout (20 * 1000 * 1000) (readCreateProcessWithExitCode ((shell $ "./" ++ testName) {cwd = Just dirName}) "")
    >>= \case
      Nothing -> do
        errorPrint "runTest: timed out"
        return Uninteresting
      Just (exitCode, _, _) ->
        case exitCode of
          ExitFailure _ -> return Uninteresting
          ExitSuccess   -> return Interesting

changeExports :: ([LIE GhcPs] -> [LIE GhcPs]) -> OPR.ParseResult -> OPR.ParseResult
changeExports f oldOrmolu  =
  let L moduleLoc oldModule    = prParsedSource oldOrmolu
      L exportsLoc oldExports  = fromJust $ hsmodExports oldModule
      newExports               = f (traceShow (concatMap ((++ " ") . lshow) oldExports) oldExports)
  in oldOrmolu {prParsedSource = L moduleLoc oldModule {hsmodExports = Just (L exportsLoc newExports)}}

changeImports :: ([LImportDecl GhcPs] -> [LImportDecl GhcPs]) -> OPR.ParseResult -> OPR.ParseResult
changeImports f oldOrmolu =
  let L moduleLoc oldModule     = prParsedSource oldOrmolu
      allImports                = hsmodImports oldModule
      newImports                = f allImports
  in oldOrmolu { prParsedSource = L moduleLoc oldModule { hsmodImports = newImports }}

changeDecls :: ([LHsDecl GhcPs] -> [LHsDecl GhcPs]) -> OPR.ParseResult -> OPR.ParseResult
changeDecls f oldOrmolu =
  let L moduleLoc oldModule     = prParsedSource oldOrmolu
      allDecls                  = hsmodDecls oldModule
      newDecls                  = f allDecls
  in oldOrmolu { prParsedSource = L moduleLoc oldModule { hsmodDecls = newDecls }}

-- | run ghc with -Wunused-binds -ddump-json and delete decls that are mentioned there
runGhc :: OPR.ParseResult -> GhcMode -> ReduceM (Maybe [BindingName])
runGhc oldOrmolu ghcMode = do
  sourceFile <- _sourceFile <$> get
  -- BUG: Ormolu is printing type level lists wrong, example: Unify (p n _ 'PTag) a' = '[ 'Sub n a']
  liftIO $ TIO.writeFile sourceFile (printModule oldOrmolu)
  let extensions = prExtensions oldOrmolu
      maybeLanguagePragmas = fmap concat . traverse getPragmaStrings . filter isLanguagePragma $ extensions
  case maybeLanguagePragmas of
    Nothing -> do
      errorPrint ""
      return Nothing
    Just languagePragmas -> do
      --debugPrint $ "Running `ghc -Wunused-binds -ddump-json` on file: " ++ sourceFile
      let (dirName, fileName) = splitFileName sourceFile
          command = 
            "ghc -Wunused-" ++ ghcModeString ++ " -ddump-json " ++ unwords (("-X" ++) <$> languagePragmas) ++ " " ++ fileName
      liftIO $ timeout (30 * 1000 * 1000) (readCreateProcessWithExitCode ((shell command) {cwd = Just dirName}) "")
        >>= \case
          Nothing -> do
            errorPrint "Process timed out."
            return Nothing
          Just (exitCode, stdout, stderr) -> case exitCode of
            ExitFailure errCode -> do
              TIO.writeFile ("/home/daniel/workspace/Reduce/debug/" ++ fileName) (printModule oldOrmolu)
              errorPrint $ "Failed running `" ++ command ++ "` with error code " ++ show errCode
              errorPrint "stdout: "
              let tempGhcOutput = map (decode . pack) . drop 1 $ lines stdout :: [Maybe GhcOutput]
              forM_ (map doc $ catMaybes tempGhcOutput) (\s -> putStrLn "" >> putStrLn s)
              errorPrint $ "stderr: " ++ stderr
              return Nothing
            ExitSuccess ->
              if stdout /= ""
                then do
                  -- dropping first line because it doesn't fit into our JSON schema
                  let maybeOutput = map (decode . pack) . drop 1 $ lines stdout :: [Maybe GhcOutput]
                  if Nothing `elem` maybeOutput
                    then do
                      errorPrint "Unable to parse some of the ghc output to JSON."
                      errorPrint $ "Unparsable Output: " ++ stdout
                      return Nothing
                    else do
                      let unusedBindingNames =
                            map (takeWhile (/= '’') . drop 1 . dropWhile (/= '‘') . doc)
                              . filter (isPrefixOf "Opt_WarnUnused" . reason)
                              . map fromJust
                              $ maybeOutput
                      return $ Just unusedBindingNames
                else return Nothing
  where ghcModeString = case ghcMode of
                          Binds   -> "binds"
                          Imports -> "imports"


mkT :: (Typeable a, Typeable b) => (b -> b) -> a -> a
mkT f = fromMaybe id (cast f)

everywhereT :: Data a => (forall b. Data b => b -> b) -> a -> a 
everywhereT f x = f (gmapT (everywhereT f) x)


mkM :: (Typeable a, Typeable b, Typeable m, Monad m) => (b -> m b) -> a -> m a
mkM f = fromMaybe return (cast f)

everywhereM :: (Monad m, Data a) => (forall b. Data b => b -> m b) -> a -> m a
everywhereM f x = do
  x' <- gmapM (everywhereM f) x
  f x'

isInProduction :: Bool
isInProduction = False

debug :: MonadIO m => (a -> m ()) -> a -> m ()
debug f s
  | isInProduction = return ()
  | otherwise = f s

debugPrint :: MonadIO m => String -> m ()
debugPrint = debug (liftIO . putStrLn . ("[debug] " ++))

errorPrint :: MonadIO m => String -> m ()
errorPrint = debug (liftIO . putStrLn . ("[error] " ++))

isLanguagePragma :: OPP.Pragma -> Bool
isLanguagePragma (PragmaLanguage _) = True
isLanguagePragma _ = False

getPragmaStrings :: OPP.Pragma -> Maybe [String]
getPragmaStrings (PragmaLanguage ss) = Just ss
getPragmaStrings _ = Nothing
