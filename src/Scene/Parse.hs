module Scene.Parse
  ( parse,
    parseCachedStmtList,
  )
where

import Context.Alias qualified as Alias
import Context.App
import Context.Decl qualified as Decl
import Context.Global qualified as Global
import Context.Locator qualified as Locator
import Context.Throw qualified as Throw
import Context.UnusedImport qualified as UnusedImport
import Context.UnusedLocalLocator qualified as UnusedLocalLocator
import Context.UnusedPreset qualified as UnusedPreset
import Context.UnusedVariable qualified as UnusedVariable
import Control.Comonad.Cofree hiding (section)
import Control.Monad
import Control.Monad.Trans
import Data.HashMap.Strict qualified as Map
import Data.Maybe
import Data.Text qualified as T
import Entity.ArgNum qualified as AN
import Entity.Attr.Data qualified as AttrD
import Entity.Attr.DataIntro qualified as AttrDI
import Entity.BaseName qualified as BN
import Entity.Cache qualified as Cache
import Entity.DeclarationName qualified as DN
import Entity.DefiniteDescription qualified as DD
import Entity.Discriminant qualified as D
import Entity.ExternalName qualified as EN
import Entity.Foreign qualified as F
import Entity.GlobalName qualified as GN
import Entity.Hint
import Entity.Ident.Reify
import Entity.IsConstLike
import Entity.Name
import Entity.Opacity qualified as O
import Entity.RawBinder
import Entity.RawIdent
import Entity.RawTerm qualified as RT
import Entity.Source qualified as Source
import Entity.Stmt
import Entity.StmtKind qualified as SK
import Path
import Scene.Parse.Core qualified as P
import Scene.Parse.Discern qualified as Discern
import Scene.Parse.Import qualified as Parse
import Scene.Parse.RawTerm
import Text.Megaparsec hiding (parse)

parse :: Source.Source -> Either Cache.Cache T.Text -> App (Either Cache.Cache ([WeakStmt], [F.Foreign]))
parse source cacheOrContent = do
  result <- parseSource source cacheOrContent
  mMainDD <- Locator.getMainDefiniteDescription source
  case mMainDD of
    Just mainDD -> do
      ensureMain (newSourceHint $ Source.sourceFilePath source) mainDD
      return result
    Nothing ->
      return result

parseSource :: Source.Source -> Either Cache.Cache T.Text -> App (Either Cache.Cache ([WeakStmt], [F.Foreign]))
parseSource source cacheOrContent = do
  let path = Source.sourceFilePath source
  case cacheOrContent of
    Left cache -> do
      let stmtList = Cache.stmtList cache
      parseCachedStmtList stmtList
      saveTopLevelNames path $ map getStmtName stmtList
      return $ Left cache
    Right content -> do
      (defList, declList) <- P.run (program source) path content
      stmtList <- Discern.discernStmtList defList
      Global.reportMissingDefinitions
      saveTopLevelNames path $ getWeakStmtName stmtList
      UnusedVariable.registerRemarks
      UnusedImport.registerRemarks
      UnusedLocalLocator.registerRemarks
      UnusedPreset.registerRemarks
      return $ Right (stmtList, declList)

saveTopLevelNames :: Path Abs File -> [(Hint, DD.DefiniteDescription)] -> App ()
saveTopLevelNames path topNameList = do
  globalNameList <- mapM (uncurry Global.lookup') topNameList
  let nameMap = Map.fromList $ zip (map snd topNameList) globalNameList
  Global.saveCurrentNameSet path nameMap

parseCachedStmtList :: [Stmt] -> App ()
parseCachedStmtList stmtList = do
  forM_ stmtList $ \stmt -> do
    case stmt of
      StmtDefine isConstLike stmtKind (SavedHint m) name impArgs expArgs _ _ -> do
        let expArgNames = map (\(_, x, _) -> toText x) expArgs
        let allArgNum = AN.fromInt $ length $ impArgs ++ expArgs
        Global.registerStmtDefine isConstLike m stmtKind name allArgNum expArgNames
      StmtDefineConst (SavedHint m) dd _ _ ->
        Global.registerStmtDefine True m (SK.Normal O.Clear) dd AN.zero []

ensureMain :: Hint -> DD.DefiniteDescription -> App ()
ensureMain m mainFunctionName = do
  mMain <- Global.lookup m mainFunctionName
  case mMain of
    Just (_, GN.TopLevelFunc _ _) ->
      return ()
    _ ->
      Throw.raiseError m "`main` is missing"

program :: Source.Source -> P.Parser ([RawStmt], [F.Foreign])
program currentSource = do
  m <- P.getCurrentHint
  sourceInfoList <- Parse.parseImportBlock currentSource
  declList <- parseForeignList
  forM_ sourceInfoList $ \(source, aliasInfoList) -> do
    let path = Source.sourceFilePath source
    namesInSource <- lift $ Global.lookupSourceNameMap m path
    lift $ Global.activateTopLevelNames namesInSource
    forM_ aliasInfoList $ \aliasInfo ->
      lift $ Alias.activateAliasInfo namesInSource aliasInfo
  forM_ declList $ \(F.Foreign name domList cod) -> do
    lift $ Decl.insDeclEnv' (DN.Ext name) domList cod
  defList <- concat <$> many parseStmt <* eof
  return (defList, declList)

parseStmt :: P.Parser [RawStmt]
parseStmt = do
  choice
    [ return <$> parseDefine O.Opaque,
      parseDefineData,
      return <$> parseDefine O.Clear,
      return <$> parseConstant,
      return <$> parseDeclare,
      return <$> parseDefineResource
    ]

parseForeignList :: P.Parser [F.Foreign]
parseForeignList = do
  choice
    [ do
        P.keyword "foreign"
        P.betweenBrace (P.manyList parseForeign),
      return []
    ]

parseForeign :: P.Parser F.Foreign
parseForeign = do
  declName <- EN.ExternalName <$> P.symbol
  lts <- P.betweenParen $ P.commaList lowType
  cod <- P.delimiter ":" >> lowType
  return $ F.Foreign declName lts cod

parseDeclare :: P.Parser RawStmt
parseDeclare = do
  P.keyword "declare"
  m <- P.getCurrentHint
  decls <- P.betweenBrace $ P.manyList $ parseDeclareItem Locator.attachCurrentLocator
  return $ RawStmtDeclare m decls

parseDefine :: O.Opacity -> P.Parser RawStmt
parseDefine opacity = do
  case opacity of
    O.Opaque ->
      P.keyword "define"
    O.Clear ->
      P.keyword "inline"
  m <- P.getCurrentHint
  (((_, name), impArgs, expArgs, codType), e) <- parseTopDefInfo
  name' <- lift $ Locator.attachCurrentLocator name
  lift $ defineFunction (SK.Normal opacity) m name' impArgs expArgs codType e

defineFunction ::
  SK.RawStmtKind ->
  Hint ->
  DD.DefiniteDescription ->
  [RawBinder RT.RawTerm] ->
  [RawBinder RT.RawTerm] ->
  RT.RawTerm ->
  RT.RawTerm ->
  App RawStmt
defineFunction stmtKind m name impArgs expArgs codType e = do
  return $ RawStmtDefine False stmtKind m name impArgs expArgs codType e

parseConstant :: P.Parser RawStmt
parseConstant = do
  P.keyword "constant"
  m <- P.getCurrentHint
  constName <- P.baseName >>= lift . Locator.attachCurrentLocator
  mImpArgs <- optional $ P.betweenBracket (P.commaList preBinder)
  t <- parseDefInfoCod m
  v <- P.betweenBrace rawExpr
  case mImpArgs of
    Nothing ->
      return $ RawStmtDefineConst m constName t v
    Just impArgs -> do
      let stmtKind = SK.Normal O.Clear
      return $ RawStmtDefine True stmtKind m constName impArgs [] t v

parseDefineData :: P.Parser [RawStmt]
parseDefineData = do
  try $ P.keyword "data"
  m <- P.getCurrentHint
  a <- P.baseName >>= lift . Locator.attachCurrentLocator
  dataArgsOrNone <- parseDataArgs
  consInfoList <- P.betweenBrace $ P.manyList parseDefineDataClause
  lift $ defineData m a dataArgsOrNone consInfoList

parseDataArgs :: P.Parser (Maybe [RawBinder RT.RawTerm])
parseDataArgs = do
  choice
    [ Just <$> try (P.argSeqOrList preBinder),
      return Nothing
    ]

defineData ::
  Hint ->
  DD.DefiniteDescription ->
  Maybe [RawBinder RT.RawTerm] ->
  [(Hint, BN.BaseName, IsConstLike, [RawBinder RT.RawTerm])] ->
  App [RawStmt]
defineData m dataName dataArgsOrNone consInfoList = do
  let dataArgs = fromMaybe [] dataArgsOrNone
  consInfoList' <- mapM modifyConstructorName consInfoList
  let consInfoList'' = modifyConsInfo D.zero consInfoList'
  let stmtKind = SK.Data dataName dataArgs consInfoList''
  let consNameList = map (\(_, consName, isConstLike, _, _) -> (consName, isConstLike)) consInfoList''
  let isConstLike = isNothing dataArgsOrNone
  let dataType = constructDataType m dataName isConstLike consNameList dataArgs
  let formRule = RawStmtDefine isConstLike stmtKind m dataName [] dataArgs (m :< RT.Tau) dataType
  introRuleList <- parseDefineDataConstructor dataType dataName dataArgs consInfoList' D.zero
  return $ formRule : introRuleList

modifyConsInfo ::
  D.Discriminant ->
  [(Hint, DD.DefiniteDescription, b, [RawBinder RT.RawTerm])] ->
  [(SavedHint, DD.DefiniteDescription, b, [RawBinder RT.RawTerm], D.Discriminant)]
modifyConsInfo d consInfoList =
  case consInfoList of
    [] ->
      []
    (m, consName, isConstLike, consArgs) : rest ->
      (SavedHint m, consName, isConstLike, consArgs, d) : modifyConsInfo (D.increment d) rest

modifyConstructorName ::
  (Hint, BN.BaseName, IsConstLike, [RawBinder RT.RawTerm]) ->
  App (Hint, DD.DefiniteDescription, IsConstLike, [RawBinder RT.RawTerm])
modifyConstructorName (mb, consName, isConstLike, yts) = do
  consName' <- Locator.attachCurrentLocator consName
  return (mb, consName', isConstLike, yts)

parseDefineDataConstructor ::
  RT.RawTerm ->
  DD.DefiniteDescription ->
  [RawBinder RT.RawTerm] ->
  [(Hint, DD.DefiniteDescription, IsConstLike, [RawBinder RT.RawTerm])] ->
  D.Discriminant ->
  App [RawStmt]
parseDefineDataConstructor dataType dataName dataArgs consInfoList discriminant = do
  case consInfoList of
    [] ->
      return []
    (m, consName, isConstLike, consArgs) : rest -> do
      let dataArgs' = map identPlusToVar dataArgs
      let consArgs' = map adjustConsArg consArgs
      let consNameList = map (\(_, c, isConstLike', _) -> (c, isConstLike')) consInfoList
      let introRule =
            RawStmtDefine
              isConstLike
              (SK.DataIntro consName dataArgs consArgs discriminant)
              m
              consName
              dataArgs
              consArgs
              dataType
              $ m :< RT.DataIntro (AttrDI.Attr {..}) consName dataArgs' (map fst consArgs')
      introRuleList <- parseDefineDataConstructor dataType dataName dataArgs rest (D.increment discriminant)
      return $ introRule : introRuleList

constructDataType ::
  Hint ->
  DD.DefiniteDescription ->
  IsConstLike ->
  [(DD.DefiniteDescription, IsConstLike)] ->
  [RawBinder RT.RawTerm] ->
  RT.RawTerm
constructDataType m dataName isConstLike consNameList dataArgs = do
  m :< RT.Data (AttrD.Attr {..}) dataName (map identPlusToVar dataArgs)

parseDefineDataClause :: P.Parser (Hint, BN.BaseName, IsConstLike, [RawBinder RT.RawTerm])
parseDefineDataClause = do
  m <- P.getCurrentHint
  consName <- P.baseName
  unless (isConsName (BN.reify consName)) $ do
    lift $ Throw.raiseError m "the name of a constructor must be capitalized"
  consArgsOrNone <- parseConsArgs
  let consArgs = fromMaybe [] consArgsOrNone
  let isConstLike = isNothing consArgsOrNone
  return (m, consName, isConstLike, consArgs)

parseConsArgs :: P.Parser (Maybe [RawBinder RT.RawTerm])
parseConsArgs = do
  choice
    [ Just <$> P.argSeqOrList parseDefineDataClauseArg,
      return Nothing
    ]

parseDefineDataClauseArg :: P.Parser (RawBinder RT.RawTerm)
parseDefineDataClauseArg = do
  choice
    [ try preAscription,
      typeWithoutIdent
    ]

parseDefineResource :: P.Parser RawStmt
parseDefineResource = do
  try $ P.keyword "resource"
  m <- P.getCurrentHint
  name <- P.baseName
  name' <- lift $ Locator.attachCurrentLocator name
  P.betweenBrace $ do
    discarder <- P.delimiter "-" >> rawExpr
    copier <- P.delimiter "-" >> rawExpr
    return $ RawStmtDefineConst m name' (m :< RT.Tau) (m :< RT.Resource name' discarder copier)

identPlusToVar :: RawBinder RT.RawTerm -> RT.RawTerm
identPlusToVar (m, x, _) =
  m :< RT.Var (Var x)

adjustConsArg :: RawBinder RT.RawTerm -> (RT.RawTerm, RawIdent)
adjustConsArg (m, x, _) =
  (m :< RT.Var (Var x), x)

getWeakStmtName :: [WeakStmt] -> [(Hint, DD.DefiniteDescription)]
getWeakStmtName =
  concatMap getWeakStmtName'

getWeakStmtName' :: WeakStmt -> [(Hint, DD.DefiniteDescription)]
getWeakStmtName' stmt =
  case stmt of
    WeakStmtDefine _ _ m name _ _ _ _ ->
      [(m, name)]
    WeakStmtDefineConst m name _ _ ->
      [(m, name)]
    WeakStmtDeclare {} ->
      []

getStmtName :: Stmt -> (Hint, DD.DefiniteDescription)
getStmtName stmt =
  case stmt of
    StmtDefine _ _ (SavedHint m) name _ _ _ _ ->
      (m, name)
    StmtDefineConst (SavedHint m) name _ _ ->
      (m, name)
