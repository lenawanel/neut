module Context.Global
  ( registerStmtDefine,
    registerDecl,
    reportMissingDefinitions,
    lookup,
    initialize,
    activateTopLevelNames,
    clearSourceNameMap,
    getSourceNameMap,
    saveCurrentNameSet,
    lookupSourceNameMap,
    lookup',
  )
where

import Context.App
import Context.App.Internal
import Context.Env qualified as Env
import Context.KeyArg qualified as KeyArg
import Context.OptimizableData qualified as OptimizableData
import Context.Tag qualified as Tag
import Context.Throw qualified as Throw
import Context.UnusedImport qualified as UnusedImport
import Context.UnusedPreset qualified as UnusedPreset
import Control.Monad
import Data.HashMap.Strict qualified as Map
import Data.Text qualified as T
import Entity.ArgNum qualified as AN
import Entity.DefiniteDescription qualified as DD
import Entity.Discriminant qualified as D
import Entity.Error (Error (MakeError))
import Entity.GlobalName
import Entity.GlobalName qualified as GN
import Entity.Hint
import Entity.Hint qualified as Hint
import Entity.IsConstLike
import Entity.Key
import Entity.OptimizableData qualified as OD
import Entity.PrimOp.FromText qualified as PrimOp
import Entity.PrimType.FromText qualified as PT
import Entity.RawDecl qualified as RDE
import Entity.Remark (Remark, RemarkLevel (Error), newRemark)
import Entity.StmtKind qualified as SK
import Entity.TopNameMap
import Path
import Prelude hiding (lookup)

registerStmtDefine ::
  IsConstLike ->
  Hint ->
  SK.BaseStmtKind x t ->
  DD.DefiniteDescription ->
  AN.ArgNum ->
  [Key] ->
  App ()
registerStmtDefine isConstLike m stmtKind name allArgNum expArgNames = do
  KeyArg.insert m name isConstLike allArgNum expArgNames
  case stmtKind of
    SK.Normal _ ->
      registerTopLevelFunc isConstLike m name allArgNum
    SK.Data dataName dataArgs consInfoList -> do
      registerData isConstLike m dataName dataArgs consInfoList
      registerAsEnumIfNecessary dataName dataArgs consInfoList
      registerAsUnaryIfNecessary dataName consInfoList
    SK.DataIntro {} ->
      return ()

registerAsEnumIfNecessary ::
  DD.DefiniteDescription ->
  [a] ->
  [(SavedHint, DD.DefiniteDescription, IsConstLike, [a], D.Discriminant)] ->
  App ()
registerAsEnumIfNecessary dataName dataArgs consInfoList =
  when (hasNoArgs dataArgs consInfoList) $ do
    OptimizableData.insert dataName OD.Enum
    mapM_ (flip OptimizableData.insert OD.Enum . (\(_, consName, _, _, _) -> consName)) consInfoList

hasNoArgs :: [a] -> [(c, DD.DefiniteDescription, b, [a], D.Discriminant)] -> Bool
hasNoArgs dataArgs consInfoList =
  null dataArgs && all (null . (\(_, _, _, consArgs, _) -> consArgs)) consInfoList

registerAsUnaryIfNecessary ::
  DD.DefiniteDescription ->
  [(b, DD.DefiniteDescription, IsConstLike, [a], D.Discriminant)] ->
  App ()
registerAsUnaryIfNecessary dataName consInfoList = do
  case (isUnary consInfoList, length consInfoList == 1) of
    (True, _) -> do
      OptimizableData.insert dataName OD.Unary
      mapM_ (flip OptimizableData.insert OD.Unary . (\(_, consName, _, _, _) -> consName)) consInfoList
    (_, True) -> do
      OptimizableData.insert dataName OD.Single
      mapM_ (flip OptimizableData.insert OD.Single . (\(_, consName, _, _, _) -> consName)) consInfoList
    _ ->
      return ()

isUnary :: [(b, DD.DefiniteDescription, IsConstLike, [a], D.Discriminant)] -> Bool
isUnary consInfoList =
  case consInfoList of
    [(_, _, _, [_], _)] ->
      True
    _ ->
      False

registerDecl :: RDE.RawDecl -> App ()
registerDecl RDE.RawDecl {..} = do
  let expArgNames = map (\(_, x, _) -> x) expArgs
  let argNum = AN.fromInt $ length $ impArgs ++ expArgs
  ensureDeclFreshness loc name
  ensureDefFreshness loc name
  KeyArg.insert loc name isConstLike argNum expArgNames
  insertToDeclNameMap name loc
  insertToNameMap name loc $ GN.TopLevelFunc argNum isConstLike

registerTopLevelFunc :: IsConstLike -> Hint -> DD.DefiniteDescription -> AN.ArgNum -> App ()
registerTopLevelFunc isConstLike m topLevelName allArgNum = do
  registerTopLevelFunc' m topLevelName $ GN.TopLevelFunc allArgNum isConstLike

registerTopLevelFunc' :: Hint -> DD.DefiniteDescription -> GN.GlobalName -> App ()
registerTopLevelFunc' m topLevelName gn = do
  ensureDefFreshness m topLevelName
  insertToNameMap topLevelName m gn

registerData ::
  IsConstLike ->
  Hint ->
  DD.DefiniteDescription ->
  [a] ->
  [(SavedHint, DD.DefiniteDescription, IsConstLike, [a], D.Discriminant)] ->
  App ()
registerData isConstLike m dataName dataArgs consInfoList = do
  ensureDefFreshness m dataName
  let dataArgNum = AN.fromInt $ length dataArgs
  let consNameArrowList = map (toConsNameArrow dataArgNum) consInfoList
  insertToNameMap dataName m $ GN.Data dataArgNum consNameArrowList isConstLike
  forM_ consNameArrowList $ \(consDD, consGN) -> do
    ensureDefFreshness m consDD
    uncurry (insertToNameMap consDD) consGN

toConsNameArrow ::
  AN.ArgNum ->
  (SavedHint, DD.DefiniteDescription, IsConstLike, [a], D.Discriminant) ->
  (DD.DefiniteDescription, (Hint, GN.GlobalName))
toConsNameArrow dataArgNum (SavedHint m, consDD, isConstLikeCons, consArgs, discriminant) = do
  let consArgNum = AN.fromInt $ length consArgs
  (consDD, (m, GN.DataIntro dataArgNum consArgNum discriminant isConstLikeCons))

lookup :: Hint.Hint -> DD.DefiniteDescription -> App (Maybe (Hint, GlobalName))
lookup m name = do
  nameMap <- readRef' nameMap
  dataSize <- Env.getDataSize m
  case Map.lookup name nameMap of
    Just kind -> do
      UnusedImport.delete $ DD.globalLocator name
      UnusedPreset.delete $ DD.moduleID name
      return $ Just kind
    Nothing
      | Just primType <- PT.fromDefiniteDescription dataSize name ->
          return $ Just (m, GN.PrimType primType)
      | Just primOp <- PrimOp.fromDefiniteDescription dataSize name ->
          return $ Just (m, GN.PrimOp primOp)
      | otherwise -> do
          return Nothing

lookup' :: Hint.Hint -> DD.DefiniteDescription -> App (Hint, GlobalName)
lookup' m name = do
  mgn <- lookup m name
  case mgn of
    Just gn ->
      return gn
    Nothing ->
      Throw.raiseError m $ "no such top-level name is defined: " <> DD.reify name

initialize :: App ()
initialize = do
  writeRef' nameMap Map.empty
  writeRef' declNameMap Map.empty

ensureDefFreshness :: Hint.Hint -> DD.DefiniteDescription -> App ()
ensureDefFreshness m name = do
  dnmap <- readRef' declNameMap
  topNameMap <- readRef' nameMap
  case (Map.lookup name dnmap, Map.member name topNameMap) of
    (Just _, False) ->
      Throw.raiseCritical m $ "`" <> DD.reify name <> "` is declared but not registered in the top name map"
    (Just mDecl, True) -> do
      removeFromDeclNameMap name
      removeFromDefNameMap name
      Tag.insertDD mDecl name m
    (Nothing, True) ->
      Throw.raiseError m $ "`" <> DD.reify name <> "` is already defined"
    (Nothing, False) ->
      return ()

ensureDeclFreshness :: Hint.Hint -> DD.DefiniteDescription -> App ()
ensureDeclFreshness m name = do
  dnmap <- readRef' declNameMap
  when (Map.member name dnmap) $ do
    Throw.raiseError m $ "`" <> DD.reify name <> "` is already declared"

reportMissingDefinitions :: App ()
reportMissingDefinitions = do
  declNameToHint <- Map.toList <$> readRef' declNameMap
  let errorList = map (uncurry declToRemark) declNameToHint
  if null errorList
    then return ()
    else Throw.throw $ MakeError errorList

declToRemark :: DD.DefiniteDescription -> Hint -> Remark
declToRemark dd m =
  newRemark m Error $ "declared but not defined: `" <> DD.reify dd <> "`"

insertToNameMap :: DD.DefiniteDescription -> Hint -> GN.GlobalName -> App ()
insertToNameMap dd m gn = do
  modifyRef' nameMap $ Map.insert dd (m, gn)

insertToDeclNameMap :: DD.DefiniteDescription -> Hint -> App ()
insertToDeclNameMap dd m = do
  modifyRef' declNameMap $ Map.insert dd m

removeFromDeclNameMap :: DD.DefiniteDescription -> App ()
removeFromDeclNameMap dd = do
  modifyRef' declNameMap $ Map.delete dd

removeFromDefNameMap :: DD.DefiniteDescription -> App ()
removeFromDefNameMap dd = do
  modifyRef' nameMap $ Map.delete dd

clearSourceNameMap :: App ()
clearSourceNameMap =
  writeRef' sourceNameMap Map.empty

getSourceNameMap :: App (Map.HashMap (Path Abs File) TopNameMap)
getSourceNameMap =
  readRef' sourceNameMap

lookupSourceNameMap :: Hint.Hint -> Path Abs File -> App TopNameMap
lookupSourceNameMap m sourcePath = do
  smap <- readRef' sourceNameMap
  case Map.lookup sourcePath smap of
    Just topLevelNameInfo -> do
      return topLevelNameInfo
    Nothing ->
      Throw.raiseCritical m $ "top-level names for " <> T.pack (toFilePath sourcePath) <> " is not registered"

activateTopLevelNames :: TopNameMap -> App ()
activateTopLevelNames namesInSource = do
  forM_ (Map.toList namesInSource) $ \(dd, (mDef, gn)) ->
    insertToNameMap dd mDef gn

saveCurrentNameSet :: Path Abs File -> TopNameMap -> App ()
saveCurrentNameSet currentPath nameMap = do
  modifyRef' sourceNameMap $ Map.insert currentPath nameMap
