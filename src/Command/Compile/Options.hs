module Command.Compile.Options where

import Prelude(String)
import Protolude

import qualified Command.Check.Options as Check

data Options = Options
  { checkOptions :: Check.Options
  , maybeOutputFile :: Maybe FilePath
  , target :: Maybe String
  , optimisation :: Maybe String
  , assemblyDir :: Maybe FilePath
  , llvmConfig :: Maybe FilePath
  , extraLibDir :: [FilePath]
  } deriving (Show)
