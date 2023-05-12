module Context.OptParse (parseCommand) where

import Context.App
import Control.Monad.IO.Class
import Data.Text qualified as T
import Entity.Command
import Entity.Config.Add qualified as Add
import Entity.Config.Build qualified as Build
import Entity.Config.Check qualified as Check
import Entity.Config.Clean qualified as Clean
import Entity.Config.Create qualified as Create
import Entity.Config.Release qualified as Release
import Entity.Config.Remark qualified as Remark
import Entity.Config.Tidy qualified as Tidy
import Entity.Config.Version qualified as Version
import Entity.ModuleURL
import Entity.OutputKind qualified as OK
import Entity.Target
import Options.Applicative

parseCommand :: App Command
parseCommand =
  liftIO $
    execParser (info (helper <*> parseOpt) fullDesc)

parseOpt :: Parser Command
parseOpt = do
  subparser $
    mconcat
      [ cmd "build" parseBuildOpt "build given target",
        cmd "clean" parseCleanOpt "remove the resulting files",
        cmd "check" parseCheckOpt "type-check specified file",
        cmd "release" parseReleaseOpt "package a tarball",
        cmd "create" parseCreateOpt "create a new module",
        cmd "add" parseGetOpt "add a dependency",
        cmd "tidy" parseTidyOpt "tidy the module dependency",
        cmd "version" parseVersionOpt "show version info"
      ]

cmd :: String -> Parser a -> String -> Mod CommandFields a
cmd name parser desc =
  command name (info (helper <*> parser) (progDesc desc))

parseBuildOpt :: Parser Command
parseBuildOpt = do
  mTarget <- optional $ argument str $ mconcat [metavar "TARGET", help "The build target"]
  mClangOpt <- optional $ strOption $ mconcat [long "clang-option", metavar "OPT", help "Options for clang"]
  installDir <- optional $ strOption $ mconcat [long "install", metavar "DIRECTORY", help "Install the resulting binary to this directory"]
  remarkCfg <- remarkConfigOpt
  outputKindList <- outputKindListOpt
  shouldSkipLink <- shouldSkipLinkOpt
  shouldExecute <- shouldExecuteOpt
  rest <- (many . strArgument) (metavar "args")
  pure $
    Build $
      Build.Config
        { Build.mTarget = Target <$> mTarget,
          Build.mClangOptString = mClangOpt,
          Build.remarkCfg = remarkCfg,
          Build.outputKindList = outputKindList,
          Build.shouldSkipLink = shouldSkipLink,
          Build.shouldExecute = shouldExecute,
          Build.installDir = installDir,
          Build.args = rest
        }

parseCleanOpt :: Parser Command
parseCleanOpt = do
  remarkCfg <- remarkConfigOpt
  pure $
    Clean $
      Clean.Config
        { Clean.remarkCfg = remarkCfg
        }

parseGetOpt :: Parser Command
parseGetOpt = do
  moduleAlias <- argument str (mconcat [metavar "ALIAS", help "The alias of the module"])
  moduleURL <- argument str (mconcat [metavar "URL", help "The URL of the archive"])
  remarkCfg <- remarkConfigOpt
  pure $
    Add $
      Add.Config
        { Add.moduleAliasText = T.pack moduleAlias,
          Add.moduleURL = ModuleURL $ T.pack moduleURL,
          Add.remarkCfg = remarkCfg
        }

parseTidyOpt :: Parser Command
parseTidyOpt = do
  remarkCfg <- remarkConfigOpt
  pure $
    Tidy $
      Tidy.Config
        { Tidy.remarkCfg = remarkCfg
        }

parseCreateOpt :: Parser Command
parseCreateOpt = do
  moduleName <- argument str (mconcat [metavar "MODULE", help "The name of the module"])
  remarkCfg <- remarkConfigOpt
  pure $
    Create $
      Create.Config
        { Create.moduleName = T.pack moduleName,
          Create.remarkCfg = remarkCfg
        }

parseVersionOpt :: Parser Command
parseVersionOpt =
  pure $
    ShowVersion $
      Version.Config {}

parseCheckOpt :: Parser Command
parseCheckOpt = do
  inputFilePath <- optional $ argument str (mconcat [metavar "INPUT", help "The path of input file"])
  padOpt <- flag True False (mconcat [long "no-padding", help "Set this to disable padding of the output"])
  remarkCfg <- remarkConfigOpt
  pure $
    Check $
      Check.Config
        { Check.mFilePathString = inputFilePath,
          Check.shouldInsertPadding = padOpt,
          Check.remarkCfg = remarkCfg
        }

parseReleaseOpt :: Parser Command
parseReleaseOpt = do
  releaseName <- argument str (mconcat [metavar "NAME", help "The name of the release"])
  remarkCfg <- remarkConfigOpt
  pure $
    Release $
      Release.Config
        { Release.getReleaseName = releaseName,
          Release.remarkCfg = remarkCfg
        }

remarkConfigOpt :: Parser Remark.Config
remarkConfigOpt = do
  shouldColorize <- colorizeOpt
  eoe <- T.pack <$> endOfEntryOpt
  pure
    Remark.Config
      { Remark.shouldColorize = shouldColorize,
        Remark.endOfEntry = eoe
      }

outputKindListOpt :: Parser [OK.OutputKind]
outputKindListOpt = do
  option outputKindListReader $ mconcat [long "emit", metavar "EMIT", help "llvm, asm, or object", value [OK.Object]]

outputKindListReader :: ReadM [OK.OutputKind]
outputKindListReader =
  eitherReader $ \input ->
    readOutputKinds $ T.splitOn "," $ T.pack input

readOutputKinds :: [T.Text] -> Either String [OK.OutputKind]
readOutputKinds kindStrList =
  case kindStrList of
    [] ->
      return []
    kindStr : rest -> do
      tmp <- readOutputKinds rest
      case kindStr of
        "llvm" ->
          return $ OK.LLVM : tmp
        "asm" ->
          return $ OK.Asm : tmp
        "object" ->
          return $ OK.Object : tmp
        _ ->
          Left $ T.unpack $ "no such output kind exists: " <> kindStr

shouldSkipLinkOpt :: Parser Bool
shouldSkipLinkOpt =
  flag
    False
    True
    ( mconcat
        [ long "skip-link",
          help "Set this to skip linking"
        ]
    )

shouldExecuteOpt :: Parser Bool
shouldExecuteOpt =
  flag
    False
    True
    ( mconcat
        [ long "execute",
          help "Run the executable after compilation"
        ]
    )

endOfEntryOpt :: Parser String
endOfEntryOpt =
  strOption (mconcat [long "end-of-entry", value "", help "String printed after each entry", metavar "STRING"])

colorizeOpt :: Parser Bool
colorizeOpt =
  flag
    True
    False
    ( mconcat
        [ long "no-color",
          help "Set this to disable colorization of the output"
        ]
    )
