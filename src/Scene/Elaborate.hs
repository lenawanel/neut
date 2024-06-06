module Scene.Elaborate (elaborate, elaborate') where

import Context.App
import Context.Cache qualified as Cache
import Context.DataDefinition qualified as DataDefinition
import Context.Definition qualified as Definition
import Context.Elaborate
import Context.Env qualified as Env
import Context.Gensym qualified as Gensym
import Context.KeyArg qualified as KeyArg
import Context.RawImportSummary qualified as RawImportSummary
import Context.Remark qualified as Remark
import Context.SymLoc qualified as SymLoc
import Context.Throw qualified as Throw
import Context.TopCandidate qualified as TopCandidate
import Context.Type qualified as Type
import Context.WeakDefinition qualified as WeakDefinition
import Control.Comonad.Cofree
import Control.Monad
import Data.Bitraversable (bimapM)
import Data.IntMap.Strict qualified as IntMap
import Data.List
import Data.Set qualified as S
import Data.Text qualified as T
import Entity.Annotation qualified as AN
import Entity.Attr.Data qualified as AttrD
import Entity.Attr.Lam qualified as AttrL
import Entity.Binder
import Entity.Cache qualified as Cache
import Entity.Const (holeVarPrefix)
import Entity.DecisionTree qualified as DT
import Entity.DefiniteDescription qualified as DD
import Entity.ExternalName qualified as EN
import Entity.Geist qualified as G
import Entity.Hint
import Entity.Ident
import Entity.Ident.Reify qualified as Ident
import Entity.IsConstLike (IsConstLike)
import Entity.LamKind qualified as LK
import Entity.Magic qualified as M
import Entity.Opacity qualified as O
import Entity.Prim qualified as P
import Entity.PrimType qualified as PT
import Entity.PrimValue qualified as PV
import Entity.Remark qualified as Remark
import Entity.Stmt
import Entity.StmtKind
import Entity.Target
import Entity.Term qualified as TM
import Entity.Term.Weaken
import Entity.WeakPrim qualified as WP
import Entity.WeakPrimValue qualified as WPV
import Entity.WeakTerm qualified as WT
import Entity.WeakTerm.ToText
import Scene.Elaborate.Infer qualified as Infer
import Scene.Elaborate.Unify qualified as Unify
import Scene.Term.Inline qualified as TM
import Scene.WeakTerm.Subst qualified as WT

elaborate :: Target -> Either Cache.Cache [WeakStmt] -> App [Stmt]
elaborate target cacheOrStmt = do
  initialize
  case cacheOrStmt of
    Left cache -> do
      let stmtList = Cache.stmtList cache
      forM_ stmtList insertStmt
      let remarkList = Cache.remarkList cache
      Remark.insertToGlobalRemarkList remarkList
      Gensym.setCountByMax $ Cache.countSnapshot cache
      return stmtList
    Right stmtList -> do
      analyzeStmtList stmtList >>= synthesizeStmtList target

analyzeStmtList :: [WeakStmt] -> App [WeakStmt]
analyzeStmtList stmtList = do
  -- mapM_ viewStmt stmtList
  forM stmtList $ \stmt -> do
    stmt' <- Infer.inferStmt stmt
    insertWeakStmt stmt'
    return stmt'

synthesizeStmtList :: Target -> [WeakStmt] -> App [Stmt]
synthesizeStmtList target stmtList = do
  -- mapM_ viewStmt stmtList
  getConstraintEnv >>= Unify.unify >>= setHoleSubst
  stmtList' <- concat <$> mapM elaborateStmt stmtList
  -- mapM_ (viewStmt . weakenStmt) stmtList'
  source <- Env.getCurrentSource
  remarkList <- Remark.getRemarkList
  tmap <- Env.getTagMap
  localVarTree <- SymLoc.get
  topCandidate <- TopCandidate.get
  rawImportSummary <- RawImportSummary.get
  countSnapshot <- Gensym.getCount
  Cache.saveCache target source $
    Cache.Cache
      { Cache.stmtList = stmtList',
        Cache.remarkList = remarkList,
        Cache.locationTree = tmap,
        Cache.countSnapshot = countSnapshot
      }
  Cache.saveCompletionCache target source $
    Cache.CompletionCache
      { Cache.localVarTree = localVarTree,
        Cache.topCandidate = topCandidate,
        Cache.rawImportSummary = rawImportSummary
      }
  Remark.insertToGlobalRemarkList remarkList
  return stmtList'

elaborateStmt :: WeakStmt -> App [Stmt]
elaborateStmt stmt = do
  case stmt of
    WeakStmtDefine isConstLike stmtKind m x impArgs expArgs codType e -> do
      stmtKind' <- elaborateStmtKind stmtKind
      e' <- elaborate' e >>= TM.inline m
      impArgs' <- mapM elaborateWeakBinder impArgs
      expArgs' <- mapM elaborateWeakBinder expArgs
      codType' <- elaborate' codType >>= TM.inline m
      let result = StmtDefine isConstLike stmtKind' (SavedHint m) x impArgs' expArgs' codType' e'
      insertStmt result
      return [result]
    WeakStmtDefineConst m dd t v -> do
      t' <- elaborate' t >>= TM.inline m
      v' <- elaborate' v >>= TM.inline m
      let result = StmtDefineConst (SavedHint m) dd t' v'
      insertStmt result
      return [result]
    WeakStmtNominal _ geistList -> do
      mapM_ elaborateGeist geistList
      return []
    WeakStmtForeign foreignList -> do
      return [StmtForeign foreignList]

elaborateGeist :: G.Geist WT.WeakTerm -> App (G.Geist TM.Term)
elaborateGeist G.Geist {..} = do
  impArgs' <- mapM elaborateWeakBinder impArgs
  expArgs' <- mapM elaborateWeakBinder expArgs
  cod' <- elaborate' cod
  return $ G.Geist {impArgs = impArgs', expArgs = expArgs', cod = cod', ..}

insertStmt :: Stmt -> App ()
insertStmt stmt = do
  case stmt of
    StmtDefine _ stmtKind (SavedHint m) f impArgs expArgs t e -> do
      Type.insert f $ weaken $ m :< TM.Pi impArgs expArgs t
      Definition.insert (toOpacity stmtKind) f (impArgs ++ expArgs) e
    StmtDefineConst (SavedHint m) dd t v -> do
      Type.insert dd $ weaken $ m :< TM.Pi [] [] t
      Definition.insert O.Clear dd [] v
    StmtForeign _ -> do
      return ()
  insertWeakStmt $ weakenStmt stmt
  insertStmtKindInfo stmt

insertWeakStmt :: WeakStmt -> App ()
insertWeakStmt stmt = do
  case stmt of
    WeakStmtDefine _ stmtKind m f impArgs expArgs codType e -> do
      WeakDefinition.insert (toOpacity stmtKind) m f impArgs expArgs codType e
    WeakStmtDefineConst m dd codType v -> do
      WeakDefinition.insert O.Clear m dd [] [] codType v
    WeakStmtNominal {} -> do
      return ()
    WeakStmtForeign {} ->
      return ()

insertStmtKindInfo :: Stmt -> App ()
insertStmtKindInfo stmt = do
  case stmt of
    StmtDefine _ stmtKind _ _ _ _ _ _ -> do
      case stmtKind of
        Normal _ ->
          return ()
        Data dataName dataArgs consInfoList -> do
          DataDefinition.insert dataName dataArgs consInfoList
        DataIntro {} ->
          return ()
    StmtDefineConst {} ->
      return ()
    StmtForeign {} ->
      return ()

elaborateStmtKind :: StmtKind WT.WeakTerm -> App (StmtKind TM.Term)
elaborateStmtKind stmtKind =
  case stmtKind of
    Normal opacity ->
      return $ Normal opacity
    Data dataName dataArgs consInfoList -> do
      dataArgs' <- mapM elaborateWeakBinder dataArgs
      let (ms, consNameList, constLikeList, consArgsList, discriminantList) = unzip5 consInfoList
      consArgsList' <- mapM (mapM elaborateWeakBinder) consArgsList
      let consInfoList' = zip5 ms consNameList constLikeList consArgsList' discriminantList
      return $ Data dataName dataArgs' consInfoList'
    DataIntro dataName dataArgs consArgs discriminant -> do
      dataArgs' <- mapM elaborateWeakBinder dataArgs
      consArgs' <- mapM elaborateWeakBinder consArgs
      return $ DataIntro dataName dataArgs' consArgs' discriminant

elaborate' :: WT.WeakTerm -> App TM.Term
elaborate' term =
  case term of
    m :< WT.Tau ->
      return $ m :< TM.Tau
    m :< WT.Var x ->
      return $ m :< TM.Var x
    m :< WT.VarGlobal name argNum ->
      return $ m :< TM.VarGlobal name argNum
    m :< WT.Pi impArgs expArgs t -> do
      impArgs' <- mapM elaborateWeakBinder impArgs
      expArgs' <- mapM elaborateWeakBinder expArgs
      t' <- elaborate' t
      return $ m :< TM.Pi impArgs' expArgs' t'
    m :< WT.PiIntro kind impArgs expArgs e -> do
      kind' <- elaborateLamAttr kind
      impArgs' <- mapM elaborateWeakBinder impArgs
      expArgs' <- mapM elaborateWeakBinder expArgs
      e' <- elaborate' e
      return $ m :< TM.PiIntro kind' impArgs' expArgs' e'
    m :< WT.PiElim e es -> do
      e' <- elaborate' e
      es' <- mapM elaborate' es
      return $ m :< TM.PiElim e' es'
    m :< WT.PiElimExact {} -> do
      Throw.raiseCritical m "Scene.Elaborate.elaborate': found a remaining `exact`"
    m :< WT.Data attr name es -> do
      es' <- mapM elaborate' es
      return $ m :< TM.Data attr name es'
    m :< WT.DataIntro attr consName dataArgs consArgs -> do
      dataArgs' <- mapM elaborate' dataArgs
      consArgs' <- mapM elaborate' consArgs
      return $ m :< TM.DataIntro attr consName dataArgs' consArgs'
    m :< WT.DataElim isNoetic oets tree -> do
      let (os, es, ts) = unzip3 oets
      es' <- mapM elaborate' es
      ts' <- mapM elaborate' ts
      tree' <- elaborateDecisionTree [] m m tree
      when (DT.isUnreachable tree') $ do
        forM_ ts' $ \t -> do
          t' <- reduceType (weaken t)
          switchSpec <- getSwitchSpec m t'
          case switchSpec of
            LiteralIntSwitch -> do
              raiseEmptyNonExhaustivePatternMatching m
            ConsSwitch consList -> do
              unless (null consList) $
                raiseEmptyNonExhaustivePatternMatching m
      return $ m :< TM.DataElim isNoetic (zip3 os es' ts') tree'
    m :< WT.Noema t -> do
      t' <- elaborate' t
      return $ m :< TM.Noema t'
    m :< WT.Embody t e -> do
      t' <- elaborate' t
      e' <- elaborate' e
      return $ m :< TM.Embody t' e'
    _ :< WT.Actual e -> do
      elaborate' e
    m :< WT.Let opacity (mx, x, t) e1 e2 -> do
      e1' <- elaborate' e1
      t' <- reduceType t
      e2' <- elaborate' e2
      return $ m :< TM.Let (WT.reifyOpacity opacity) (mx, x, t') e1' e2'
    m :< WT.Hole h es -> do
      fillHole m h es >>= elaborate'
    m :< WT.Prim prim ->
      case prim of
        WP.Type t ->
          return $ m :< TM.Prim (P.Type t)
        WP.Value primValue ->
          case primValue of
            WPV.Int t x -> do
              t' <- reduceWeakType t >>= elaborate'
              case t' of
                _ :< TM.Prim (P.Type (PT.Int size)) ->
                  return $ m :< TM.Prim (P.Value (PV.Int size x))
                _ :< TM.Prim (P.Type (PT.Float size)) ->
                  return $ m :< TM.Prim (P.Value (PV.Float size (fromInteger x)))
                _ -> do
                  Throw.raiseError m $
                    "The term `"
                      <> T.pack (show x)
                      <> "` is an integer, but its type is: "
                      <> toText (weaken t')
            WPV.Float t x -> do
              t' <- reduceWeakType t >>= elaborate'
              case t' of
                _ :< TM.Prim (P.Type (PT.Float size)) ->
                  return $ m :< TM.Prim (P.Value (PV.Float size x))
                _ -> do
                  Throw.raiseError m $
                    "The term `"
                      <> T.pack (show x)
                      <> "` is a float, but its type is: "
                      <> toText (weaken t')
            WPV.Op op ->
              return $ m :< TM.Prim (P.Value (PV.Op op))
            WPV.StaticText t text -> do
              t' <- elaborate' t
              return $ m :< TM.Prim (P.Value (PV.StaticText t' text))
    m :< WT.Magic magic -> do
      case magic of
        M.External domList cod name args varArgs -> do
          let expected = length domList
          let actual = length args
          when (actual /= length domList) $ do
            Throw.raiseError m $
              "The external function `"
                <> EN.reify name
                <> "` expects "
                <> T.pack (show expected)
                <> " arguments, but found "
                <> T.pack (show actual)
                <> "."
          args' <- mapM elaborate' args
          let (vArgs, vTypes) = unzip varArgs
          vArgs' <- mapM elaborate' vArgs
          return $ m :< TM.Magic (M.External domList cod name args' (zip vArgs' vTypes))
        _ -> do
          magic' <- mapM elaborate' magic
          return $ m :< TM.Magic magic'
    m :< WT.Annotation remarkLevel annot e -> do
      e' <- elaborate' e
      case annot of
        AN.Type t -> do
          t' <- elaborate' t
          let message = "admitting `" <> toText (weaken t') <> "`"
          let typeRemark = Remark.newRemark m remarkLevel message
          Remark.insertRemark typeRemark
          return e'
    m :< WT.Resource resourceID discarder copier -> do
      discarder' <- elaborate' discarder
      copier' <- elaborate' copier
      return $ m :< TM.Resource resourceID discarder' copier'
    m :< WT.Use {} -> do
      Throw.raiseCritical m "Scene.Elaborate.elaborate': found a remaining `use`"

elaborateWeakBinder :: BinderF WT.WeakTerm -> App (BinderF TM.Term)
elaborateWeakBinder (m, x, t) = do
  t' <- elaborate' t
  return (m, x, t')

elaborateLamAttr :: AttrL.Attr WT.WeakTerm -> App (AttrL.Attr TM.Term)
elaborateLamAttr (AttrL.Attr {lamKind, identity}) =
  case lamKind of
    LK.Normal codType -> do
      codType' <- elaborate' codType
      return $ AttrL.Attr {lamKind = LK.Normal codType', identity}
    LK.Fix xt -> do
      xt' <- elaborateWeakBinder xt
      return $ AttrL.Attr {lamKind = LK.Fix xt', identity}

type ClauseContext =
  [(Ident, (DD.DefiniteDescription, IsConstLike, [Ident]))]

data PatternTree
  = Leaf
  | Node T.Text IsConstLike [(Ident, PatternTree)]
  deriving (Show)

fromPatternTree :: Hint -> (Ident, PatternTree) -> WT.WeakTerm
fromPatternTree m (x, t) =
  case t of
    Leaf ->
      m :< WT.Var x
    Node func isConstLike args -> do
      if isConstLike
        then m :< WT.Var (I (func, 0))
        else do
          let args' = map (fromPatternTree m) args
          m :< WT.PiElim (m :< WT.Var (I (func, 0))) args'

suppress :: (Ident, PatternTree) -> (Ident, PatternTree)
suppress (x, tree) = do
  case tree of
    Leaf ->
      (suppress' x, Leaf)
    Node dd isConstLike args -> do
      (suppress' x, Node dd isConstLike (map suppress args))

suppress' :: Ident -> Ident
suppress' (I (_, i)) =
  I (holeVarPrefix, i)

makeTree :: Hint -> ClauseContext -> App (Ident, PatternTree)
makeTree m ctx =
  case ctx of
    [] ->
      Throw.raiseCritical m "Scene.Elaborate.makeTree: invalid argument (empty context)"
    [(v, (dd, isConstLike, args))] ->
      return (v, Node (DD.localLocator dd) isConstLike (map (,Leaf) args))
    (v, (dd, isConstLike, args)) : rest -> do
      (v', t) <- makeTree m rest
      return (v', graft v (Node (DD.localLocator dd) isConstLike (map (,Leaf) args)) t)

graft :: Ident -> PatternTree -> PatternTree -> PatternTree
graft from to tree =
  case tree of
    Leaf ->
      Leaf
    Node dd isConstLike children -> do
      Node dd isConstLike $ flip map children $ \(x, t) -> do
        if x == from
          then (x, to)
          else (x, graft from to t)

holeIdent :: Ident
holeIdent =
  I (holeVarPrefix, 0)

elaborateDecisionTree ::
  ClauseContext ->
  Hint ->
  Hint ->
  DT.DecisionTree WT.WeakTerm ->
  App (DT.DecisionTree TM.Term)
elaborateDecisionTree ctx mOrig m tree =
  case tree of
    DT.Leaf xs letSeq body -> do
      letSeq' <- mapM (bimapM elaborateWeakBinder elaborate') letSeq
      body' <- elaborate' body
      return $ DT.Leaf xs letSeq' body'
    DT.Unreachable ->
      return DT.Unreachable
    DT.Switch (cursor, cursorType) (fallbackClause, clauseList) -> do
      cursorType' <- reduceWeakType cursorType >>= elaborate'
      switchSpec <- getSwitchSpec m cursorType'
      case switchSpec of
        LiteralIntSwitch -> do
          when (DT.isUnreachable fallbackClause) $ do
            raiseIntegerNonExhaustivePatternMatching m
          fallbackClause' <- elaborateDecisionTree ctx mOrig m fallbackClause
          clauseList' <- mapM (elaborateClause mOrig cursor ctx) clauseList
          return $ DT.Switch (cursor, cursorType') (fallbackClause', clauseList')
        ConsSwitch consList -> do
          let activeConsList = DT.getConstructors clauseList
          let diff = S.difference (S.fromList consList) (S.fromList activeConsList)
          if S.size diff == 0
            then do
              clauseList' <- mapM (elaborateClause mOrig cursor ctx) clauseList
              return $ DT.Switch (cursor, cursorType') (DT.Unreachable, clauseList')
            else do
              case fallbackClause of
                DT.Unreachable -> do
                  t <- makeTree mOrig ctx
                  let t' = fromPatternTree m $ suppress t
                  uncoveredPatterns <- forM (S.toList diff) $ \(consDD, isConstLike) -> do
                    let cons = m :< WT.Var (I (DD.localLocator consDD, 0))
                    if isConstLike
                      then do
                        let sub = IntMap.fromList [(Ident.toInt cursor, Right cons)]
                        WT.subst sub t'
                      else do
                        (_, keys) <- KeyArg.lookup m consDD
                        let expArgNum = length keys
                        let holes = map (const $ m :< WT.Var holeIdent) [1 .. expArgNum]
                        let tip = m :< WT.PiElim cons holes
                        let sub = IntMap.fromList [(Ident.toInt cursor, Right tip)]
                        WT.subst sub t'
                  let uncoveredPatterns' = T.concat $ flip map uncoveredPatterns $ \ex -> do
                        "- " <> toText ex <> "\n"
                  Throw.raiseError mOrig $
                    "This pattern matching does not cover:\n" <> uncoveredPatterns'
                _ -> do
                  fallbackClause' <- elaborateDecisionTree ctx mOrig m fallbackClause
                  clauseList' <- mapM (elaborateClause mOrig cursor ctx) clauseList
                  return $ DT.Switch (cursor, cursorType') (fallbackClause', clauseList')

elaborateClause :: Hint -> Ident -> ClauseContext -> DT.Case WT.WeakTerm -> App (DT.Case TM.Term)
elaborateClause mOrig cursor ctx decisionCase = do
  case decisionCase of
    DT.LiteralIntCase mPat i cont -> do
      cont' <- elaborateDecisionTree ctx mOrig mPat cont
      return $ DT.LiteralIntCase mPat i cont'
    DT.ConsCase {..} -> do
      let (dataTerms, dataTypes) = unzip dataArgs
      dataTerms' <- mapM elaborate' dataTerms
      dataTypes' <- mapM elaborate' dataTypes
      consArgs' <- mapM elaborateWeakBinder consArgs
      let consArgIdents = map (\(_, x, _) -> x) consArgs
      let consContext = (cursor, (consDD, isConstLike, consArgIdents))
      cont' <- elaborateDecisionTree (consContext : ctx) mOrig mCons cont
      return $
        decisionCase
          { DT.dataArgs = zip dataTerms' dataTypes',
            DT.consArgs = consArgs',
            DT.cont = cont'
          }

raiseIntegerNonExhaustivePatternMatching :: Hint -> App a
raiseIntegerNonExhaustivePatternMatching m =
  Throw.raiseError m "Pattern matching on integers must have a fallback clause"

raiseEmptyNonExhaustivePatternMatching :: Hint -> App a
raiseEmptyNonExhaustivePatternMatching m =
  Throw.raiseError m "Empty pattern matching can only be performed on empty ADT values"

reduceType :: WT.WeakTerm -> App TM.Term
reduceType e = do
  reduceWeakType e >>= elaborate'

data SwitchSpec
  = LiteralIntSwitch
  | ConsSwitch [(DD.DefiniteDescription, IsConstLike)]

getSwitchSpec :: Hint -> TM.Term -> App SwitchSpec
getSwitchSpec m cursorType = do
  case cursorType of
    _ :< TM.Data (AttrD.Attr {..}) _ _ -> do
      return $ ConsSwitch consNameList
    _ :< TM.Prim (P.Type (PT.Int _)) -> do
      return LiteralIntSwitch
    _ ->
      Throw.raiseError m $
        "This term is expected to be an ADT value or an integer, but it's not:\n"
          <> toText (weaken cursorType)
