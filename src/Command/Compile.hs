{-# LANGUAGE CPP, FlexibleContexts, OverloadedStrings #-}
module Command.Compile where

import qualified Data.List.NonEmpty as NonEmpty
import Data.Monoid
import GHC.IO.Handle
import Options.Applicative
import System.Directory
import System.FilePath
import System.IO
import System.IO.Temp

import qualified Backend.Compile as Compile
import qualified Backend.Target as Target
import qualified Command.Check as Check
import qualified Command.Check.Options as Check
import Command.Compile.Options
import Error
import qualified Processor.Files as Processor
import qualified Processor.Result as Processor
import Syntax.Extern
import Util

optionsParserInfo :: ParserInfo Options
optionsParserInfo = info (helper <*> optionsParser)
  $ fullDesc
  <> progDesc "Compile a Sixten program"
  <> header "sixten compile"

optionsParser :: Parser Options
optionsParser = Options
  <$> Check.optionsParser
  <*> optional (strOption
    $ long "output"
    <> short 'o'
    <> metavar "FILE"
    <> help "Write output to FILE"
    <> action "file"
    )
  <*> optional (strOption
    $ long "target"
    <> short 't'
    <> metavar "TARGET"
    <> help "Compile for CPU architecture TARGET"
    <> completeWith Target.architectures
    )
  <*> optional (strOption
    $ long "optimise"
    <> short 'O'
    <> metavar "LEVEL"
    <> help "Set the optimisation level to LEVEL"
    <> completeWith ["0", "1", "2", "3"]
    )
  <*> optional (strOption
    $ long "save-assembly"
    <> short 'S'
    <> metavar "DIR"
    <> help "Save intermediate assembly files to DIR"
    <> action "directory"
    )
  <*> optional (strOption
    $ long "llvm-config"
    <> metavar "PATH"
    <> help "Path to the llvm-config binary."
    <> action "file"
    )
  <*> many (strOption
    $ long "extra-lib-dir"
    <> metavar "DIR"
    <> help "Path where extra libraries (gc-lib.lib, etc.) exist."
    <> action "directory"
    )

compile
  :: Options
  -> (Processor.Result (FilePath, [Error]) -> IO k)
  -> IO k
compile opts onResult = case maybe (Right Target.defaultTarget) Target.findTarget $ target opts of
  Left err -> onResult $ Processor.Failure $ pure err
  Right tgt ->
    withAssemblyDir (assemblyDir opts) $ \asmDir ->
    withOutputFile (maybeOutputFile opts) $ \outputFile ->
    withLogHandle (Check.logFile . checkOptions $ opts) $ \logHandle -> do
      let linkedLlFileName = asmDir </> firstFileName <.> "linked" <.> "ll"
      procResult <- Processor.processFiles Processor.Arguments
        { Processor.sourceFiles = inputFiles
        , Processor.assemblyDir = asmDir
        , Processor.target = tgt
        , Processor.logHandle = logHandle
        , Processor.verbosity = Check.verbosity . checkOptions $ opts
        }
      case procResult of
        Processor.Failure errs -> onResult $ Processor.Failure errs
        Processor.Success (result, errs) -> do
          Compile.compile opts Compile.Arguments
            { Compile.cFiles = [cFile | (C, cFile) <- Processor.externFiles result]
            , Compile.llFiles = Processor.llFiles result
            , Compile.linkedLlFileName = linkedLlFileName
            , Compile.target = tgt
            , Compile.outputFile = outputFile
            }
          onResult $ Processor.Success (outputFile, errs)
  where
    -- TODO should use the main file instead
    firstInputFile = case inputFiles of
      x NonEmpty.:| _ -> x
    (firstInputDir, firstInputFileName) = splitFileName firstInputFile
    firstFileName = dropExtension firstInputFileName

    withAssemblyDir Nothing k = withSystemTempDirectory "sixten" k
    withAssemblyDir (Just dir) k = do
      createDirectoryIfMissing True dir
      k dir

    withOutputFile Nothing k
#ifndef mingw32_HOST_OS
      = withTempFile firstInputDir firstFileName $ \outputFile outputFileHandle -> do
#else
      = withTempFile firstInputDir (firstFileName <> ".exe") $ \outputFile outputFileHandle -> do
        -- On Windows executable should have suffix @.exe@.
#endif
        hClose outputFileHandle
        k outputFile
    withOutputFile (Just o) k = do
      o' <- makeAbsolute o
      k o'

    withLogHandle Nothing k = k stdout
    withLogHandle (Just file) k = Util.withFile file WriteMode k

    inputFiles = Check.inputFiles . checkOptions $ opts

command :: ParserInfo (IO ())
command = go <$> optionsParserInfo
  where
    go opts = compile opts $ \res -> case res of
      Processor.Failure errs -> mapM_ printError errs
      Processor.Success (_fp, errs) -> mapM_ printError errs
