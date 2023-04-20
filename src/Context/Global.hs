module Context.Global
  ( registerStmtDefine,
    registerStmtDefineResource,
    registerStmtExport,
    lookup,
    lookupStrict,
    initialize,
    lookupSourceNameMap,
    activateTopLevelNamesInSource,
    saveCurrentNameSet,
  )
where

import Context.App
import Context.App.Internal
import Context.Enum qualified as Enum
import Context.Env qualified as Env
import Context.Implicit qualified as Implicit
import Context.Throw qualified as Throw
import Control.Monad
import Data.HashMap.Strict qualified as Map
import Data.Text qualified as T
import Entity.ArgNum qualified as AN
import Entity.Arity qualified as A
import Entity.Binder
import Entity.DefiniteDescription qualified as DD
import Entity.Discriminant qualified as D
import Entity.GlobalName
import Entity.GlobalName qualified as GN
import Entity.Hint
import Entity.Hint qualified as Hint
import Entity.IsConstLike
import Entity.NameArrow qualified as NA
import Entity.PrimOp.FromText qualified as PrimOp
import Entity.PrimType.FromText qualified as PT
import Entity.Source qualified as Source
import Entity.Stmt as ST
import Path
import Prelude hiding (lookup)

type NameMap = Map.HashMap DD.DefiniteDescription GN.GlobalName

registerStmtDefine ::
  IsConstLike ->
  Hint ->
  ST.StmtKindF a ->
  DD.DefiniteDescription ->
  AN.ArgNum ->
  AN.ArgNum ->
  App ()
registerStmtDefine isConstLike m stmtKind name impArgNum allArgNum = do
  case stmtKind of
    ST.Normal _ ->
      registerTopLevelFunc isConstLike m name impArgNum allArgNum
    ST.Data dataName dataArgs consInfoList -> do
      registerData isConstLike m dataName dataArgs consInfoList
      registerAsEnumIfNecessary dataName dataArgs consInfoList
    ST.DataIntro {} ->
      return ()

registerAsEnumIfNecessary ::
  DD.DefiniteDescription ->
  [BinderF a] ->
  [(DD.DefiniteDescription, IsConstLike, [BinderF a], D.Discriminant)] ->
  App ()
registerAsEnumIfNecessary dataName dataArgs consInfoList =
  when (hasNoArgs dataArgs consInfoList) $ do
    Enum.insert dataName
    mapM_ (Enum.insert . (\(consName, _, _, _) -> consName)) consInfoList

hasNoArgs :: [BinderF a] -> [(DD.DefiniteDescription, b, [BinderF a], D.Discriminant)] -> Bool
hasNoArgs dataArgs consInfoList =
  null dataArgs && null (concatMap (\(_, _, consArgs, _) -> consArgs) consInfoList)

registerTopLevelFunc :: IsConstLike -> Hint -> DD.DefiniteDescription -> AN.ArgNum -> AN.ArgNum -> App ()
registerTopLevelFunc isConstLike m topLevelName impArgNum allArgNum = do
  topNameMap <- readRef' nameMap
  ensureFreshness m topNameMap topLevelName
  let arity = A.fromInt (AN.reify allArgNum)
  -- let arity = A.fromInt (AN.reify impArgNum + AN.reify expArgNum)
  modifyRef' nameMap $ Map.insert topLevelName $ GN.TopLevelFunc arity isConstLike
  Implicit.insert topLevelName impArgNum

registerData ::
  IsConstLike ->
  Hint ->
  DD.DefiniteDescription ->
  [BinderF a] ->
  [(DD.DefiniteDescription, IsConstLike, [BinderF a], D.Discriminant)] ->
  App ()
registerData isConstLike m dataName dataArgs consInfoList = do
  topNameMap <- readRef' nameMap
  ensureFreshness m topNameMap dataName
  let consList = map (\(consName, _, _, _) -> consName) consInfoList
  let dataArity = A.fromInt $ length dataArgs
  let dataArgNum = AN.fromInt (length dataArgs)
  modifyRef' nameMap $ Map.insert dataName $ GN.Data dataArity consList isConstLike
  forM_ consInfoList $ \(consName, isConstLikeCons, consArgs, discriminant) -> do
    topNameMap' <- readRef' nameMap
    ensureFreshness m topNameMap' consName
    let consArity = A.fromInt $ length consArgs
    modifyRef' nameMap $ Map.insert consName $ GN.DataIntro dataArity consArity discriminant isConstLikeCons
    Implicit.insert consName dataArgNum

registerStmtDefineResource :: Hint -> DD.DefiniteDescription -> App ()
registerStmtDefineResource m resourceName = do
  topNameMap <- readRef' nameMap
  ensureFreshness m topNameMap resourceName
  modifyRef' nameMap $ Map.insert resourceName GN.Resource

registerStmtExport :: NA.NameArrow -> App ()
registerStmtExport arrow = do
  case arrow of
    NA.Function ((m, alias), (_, original, gn)) -> do
      registerStmtExport' m alias $ GN.Alias original gn
    NA.Variant ((mData, dataAlias), (_, dataDD, dataGN)) consArrowList consNameList -> do
      registerStmtExport' mData dataAlias $ GN.AliasData dataDD consNameList dataGN
      mapM_ (registerStmtExport . NA.Function) consArrowList

registerStmtExport' ::
  Hint ->
  DD.DefiniteDescription ->
  GlobalName ->
  App ()
registerStmtExport' m alias gn = do
  topNameMap <- readRef' nameMap
  ensureFreshness m topNameMap alias
  modifyRef' nameMap $ Map.insert alias gn

lookup :: Hint.Hint -> DD.DefiniteDescription -> App (Maybe GlobalName)
lookup m name = do
  nameMap <- readRef' nameMap
  dataSize <- Env.getDataSize m
  case Map.lookup name nameMap of
    Just kind ->
      return $ Just kind
    Nothing
      | Just primType <- PT.fromDefiniteDescription dataSize name ->
          return $ Just $ GN.PrimType primType
      | Just primOp <- PrimOp.fromDefiniteDescription dataSize name ->
          return $ Just $ GN.PrimOp primOp
      | otherwise -> do
          return Nothing

lookupStrict :: Hint.Hint -> DD.DefiniteDescription -> App GlobalName
lookupStrict m name = do
  mGlobalName <- lookup m name
  case mGlobalName of
    Just globalName ->
      return globalName
    Nothing ->
      Throw.raiseCritical m $ "the top-level " <> DD.reify name <> " doesn't have its global name"

initialize :: App ()
initialize = do
  writeRef' nameMap Map.empty

ensureFreshness :: Hint.Hint -> NameMap -> DD.DefiniteDescription -> App ()
ensureFreshness m topNameMap name = do
  when (Map.member name topNameMap) $
    Throw.raiseError m $
      "`" <> DD.reify name <> "` is already defined"

insertToSourceNameMap :: Path Abs File -> [(DD.DefiniteDescription, GN.GlobalName)] -> App ()
insertToSourceNameMap sourcePath topLevelNameInfo = do
  modifyRef' sourceNameMap $ Map.insert sourcePath $ Map.fromList topLevelNameInfo

lookupSourceNameMap :: Hint.Hint -> Path Abs File -> App (Map.HashMap DD.DefiniteDescription GN.GlobalName)
lookupSourceNameMap m sourcePath = do
  smap <- readRef' sourceNameMap
  case Map.lookup sourcePath smap of
    Just topLevelNameInfo ->
      return topLevelNameInfo
    Nothing ->
      Throw.raiseCritical m $ "top-level names for " <> T.pack (toFilePath sourcePath) <> " is not registered"

activateTopLevelNamesInSource :: Hint.Hint -> Source.Source -> App ()
activateTopLevelNamesInSource m source = do
  namesInSource <- lookupSourceNameMap m $ Source.sourceFilePath source
  modifyRef' nameMap $ Map.union namesInSource

saveCurrentNameSet :: Path Abs File -> [NA.NameArrow] -> App ()
saveCurrentNameSet currentPath nameArrowList = do
  nameList' <- fmap concat $ forM nameArrowList $ \nameArrow -> do
    case nameArrow of
      NA.Function innerNameArrow ->
        return [reifyNameArrow innerNameArrow]
      NA.Variant ((_, dataAlias), (_, dataDD, dataGN)) consArrowList consNameList -> do
        let gn = GN.AliasData dataDD consNameList dataGN
        let consInfoList' = map reifyNameArrow consArrowList
        return $ (dataAlias, gn) : consInfoList'
  insertToSourceNameMap currentPath nameList'

reifyNameArrow :: NA.InnerNameArrow -> (DD.DefiniteDescription, GN.GlobalName)
reifyNameArrow ((_, aliasName), (_, origName, globalName)) = do
  (aliasName, GN.Alias origName globalName)
