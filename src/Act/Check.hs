module Act.Check
  ( check,
    Config (..),
  )
where

import qualified Context.App as App
import qualified Context.Locator as Locator
import qualified Context.Log as Log
import qualified Context.Mode as Mode
import qualified Context.Module as Module
import qualified Context.Path as Path
import qualified Context.Throw as Throw
import Control.Monad
import qualified Data.HashMap.Strict as Map
import qualified Data.Text as T
import Entity.Module
import qualified Entity.Module.Reflect as Module
import Entity.Source
import Path
import Path.IO
import Scene.Elaborate
import Scene.Parse
import Scene.Unravel

data Config = Config
  { mFilePathString :: Maybe FilePath,
    logCfg :: Log.Config,
    throwCfg :: Throw.Config,
    pathCfg :: Path.Config
  }

check :: Mode.Mode -> Config -> IO ()
check mode cfg = do
  throwCtx <- Mode.throwCtx mode $ throwCfg cfg
  logCtx <- Mode.logCtx mode $ logCfg cfg
  pathCtx <- Mode.pathCtx mode $ pathCfg cfg
  Throw.run throwCtx (Log.printLog logCtx) $ do
    ensureNotInLibDir throwCtx pathCtx "check"
    mainModule <- Module.fromCurrentPath throwCtx
    moduleCtx <-
      Mode.moduleCtx mode $
        Module.Config
          { Module.mainModule = mainModule,
            Module.throwCtx = throwCtx,
            Module.pathCtx = pathCtx
          }
    case mFilePathString cfg of
      Just filePathStr -> do
        filePath <- resolveFile' filePathStr
        check' mode throwCtx logCtx moduleCtx filePath mainModule
      Nothing -> do
        forM_ (Map.elems $ moduleTarget mainModule) $ \relPath ->
          check' mode throwCtx logCtx moduleCtx (getSourceDir mainModule </> relPath) mainModule

check' ::
  Mode.Mode ->
  Throw.Context ->
  Log.Context ->
  Module.Context ->
  Path Abs File ->
  Module ->
  IO ()
check' mode throwCtx logCtx moduleCtx filePath mainModule = do
  ensureFileModuleSanity throwCtx filePath mainModule
  let initialSource = Source {sourceModule = mainModule, sourceFilePath = filePath}
  (_, _, hasCacheSet, _, sourceAliasMap, dependenceSeq) <- unravel mode throwCtx moduleCtx mainModule initialSource
  let ctxCfg =
        App.Config
          { App.mode = mode,
            App.throwCtx = throwCtx,
            App.logCtx = logCtx,
            App.cancelAllocFlagConf = False,
            App.mainModuleConf = mainModule,
            App.initialSourceConf = initialSource,
            App.sourceAliasMapConf = sourceAliasMap,
            App.hasCacheSetConf = hasCacheSet
          }
  forM_ dependenceSeq $ \source -> do
    ctx <- App.new ctxCfg source
    mMainFunctionName <- Locator.getMainFunctionName (App.locator ctx) source
    case mMainFunctionName of
      Just mainName ->
        void $ parseMain ctx mainName source >>= elaborateMain ctx mainName source
      Nothing ->
        void $ parseOther ctx source >>= elaborateOther ctx source

ensureFileModuleSanity :: Throw.Context -> Path Abs File -> Module -> IO ()
ensureFileModuleSanity ctx filePath mainModule = do
  unless (isProperPrefixOf (getSourceDir mainModule) filePath) $ do
    Throw.raiseError' ctx "the specified file is not in the current module"

ensureNotInLibDir :: Throw.Context -> Path.Context -> T.Text -> IO ()
ensureNotInLibDir throwCtx pathCtx commandName = do
  currentDir <- getCurrentDir
  libDir <- Path.getLibraryDirPath pathCtx
  when (isProperPrefixOf libDir currentDir) $
    Throw.raiseError' throwCtx $
      "the subcommand `" <> commandName <> "` cannot be run under the library directory"
