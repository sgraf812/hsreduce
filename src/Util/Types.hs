module Util.Types where

import Data.Void
import qualified Text.Megaparsec as M
import Path
import qualified Data.Text as T
import Control.Applicative
import Control.Monad.Reader
import Control.Monad.State.Strict
import Data.Aeson
import GHC.Generics (Generic)
import GHC
import Outputable

runR :: RConf -> RState -> R a -> IO (a, RState)
runR c st (R a) = runStateT (runReaderT a c) st

newtype R a
  = R (ReaderT RConf (StateT RState IO) a)
  deriving (Functor, Applicative, Monad, MonadIO, MonadReader RConf, MonadState RState, Alternative, MonadPlus)

data RConf
  = RConf
      { _test       :: Path Abs File,
        _sourceFile :: Path Abs File
      }

data RState
  = RState
      { _pragmas     :: ![Pragma]
      , _parsed      :: !ParsedSource
      , _renamed     :: Maybe RenamedSource
      , _typechecked :: Maybe TypecheckedSource
      , _isAlive     :: !Bool
      }

showState :: RState -> T.Text
showState (RState prags ps _ _ _)  =
  T.unlines
  $ map (T.pack . show) prags
  ++ [T.pack . showSDocUnsafe . ppr . unLoc $ ps]


data Span
  = Span
      { file      :: !T.Text
      , startLine :: !Int
      , startCol  :: !Int
      , endLine   :: !Int
      , endCol    :: !Int
      }
  deriving (Eq, Generic, Show)
instance FromJSON Span


data GhcOutput
  = GhcOutput
      { span   :: !(Maybe Span),
        doc    :: !T.Text,
        reason :: !(Maybe T.Text)
      }
  deriving (Eq, Generic, Show)
instance FromJSON GhcOutput

data Tool = Ghc | Cabal deriving Show
data GhcMode = Binds | Imports | ParseIndent | Other

data Interesting = Interesting | Uninteresting
  deriving (Show)

-- TODO: maybe use another type than text for OPTION and INCLUDE
data Pragma = Language T.Text | OptionsGhc T.Text | Include T.Text
  deriving Eq

showExtension :: Pragma -> T.Text
showExtension (Language e)   = e
showExtension (OptionsGhc _) = ""
showExtension (Include _)    = ""

instance Show Pragma where
  show (Language e)   = "{-# LANGUAGE "    ++ T.unpack e ++ " #-}"
  show (OptionsGhc o) = "{-# OPTIONS_GHC " ++ T.unpack o ++ " #-}"
  show (Include i)    = "{-# INCLUDE "     ++ T.unpack i ++ " #-}"

type Parser = M.Parsec Void T.Text
