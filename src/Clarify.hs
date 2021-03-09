--
-- clarification == polarization + closure conversion + linearization
--
module Clarify
  ( clarify,
  )
where

import Clarify.Linearize
import Clarify.Sigma
import Clarify.Utility
import Control.Monad.State.Lazy
import Data.Basic
import Data.Comp
import Data.Env
import qualified Data.HashMap.Lazy as Map
import qualified Data.IntMap as IntMap
import Data.List (nubBy)
import Data.Log
import Data.LowType
import Data.Maybe (catMaybes)
import Data.Term
import qualified Data.Text as T
import Reduce.Comp

clarify :: [Stmt] -> WithEnv CompPlus
clarify ss = do
  e <- clarifyStmt IntMap.empty ss
  reduceCompPlus e

clarifyStmt :: TypeEnv -> [Stmt] -> WithEnv CompPlus
clarifyStmt tenv ss =
  case ss of
    [] -> do
      ph <- gets phase
      m <- newHint ph 1 1 <$> getCurrentFilePath
      return (m, CompUpIntro (m, ValueInt 64 0))
    StmtLet m (mx, x, t) e : cont -> do
      e' <- clarifyTerm tenv e >>= reduceCompPlus
      insCompEnv (asText x <> "_" <> T.pack (show (asInt x))) False [] e'
      let app = (m, CompPiElimDownElim (m, ValueConst $ asText x <> "_" <> T.pack (show (asInt x))) [])
      cont' <- clarifyStmt (insTypeEnv [(mx, x, t)] tenv) cont
      holeVarName <- newNameWith' "hole"
      return (m, CompUpElim holeVarName app cont')
    StmtResourceType m name discarder copier : cont -> do
      discarder' <- toSwitcherBranch m tenv discarder
      copier' <- toSwitcherBranch m tenv copier
      registerSwitcher m name discarder' copier'
      clarifyStmt tenv cont

clarifyTerm :: TypeEnv -> TermPlus -> WithEnv CompPlus
clarifyTerm tenv term =
  case term of
    (m, TermTau) ->
      returnImmediateS4 m
    (m, TermUpsilon x) -> do
      senv <- gets substEnv
      if not $ IntMap.member (asInt x) senv
        then return (m, CompUpIntro (m, ValueUpsilon x))
        else return (m, CompPiElimDownElim (m, ValueConst $ asText x <> "_" <> T.pack (show (asInt x))) [])
    (m, TermPi {}) ->
      returnClosureS4 m
    (m, TermPiIntro mxts e) -> do
      e' <- clarifyTerm (insTypeEnv mxts tenv) e
      fvs <- nubFVS <$> chainOf tenv term
      retClosure tenv Nothing fvs m mxts e'
    (m, TermPiElim e es) -> do
      es' <- mapM (clarifyPlus tenv) es
      e' <- clarifyTerm tenv e
      callClosure m e' es'
    (m, TermFix (mx, x, t) mxts e) -> do
      e' <- clarifyTerm (insTypeEnv ((mx, x, t) : mxts) tenv) e
      fvs <- nubFVS <$> chainOf tenv term
      retClosure tenv (Just x) fvs m mxts e'
    (m, TermConst x) ->
      clarifyConst tenv m x
    (m, TermInt size l) ->
      return (m, CompUpIntro (m, ValueInt size l))
    (m, TermFloat size l) ->
      return (m, CompUpIntro (m, ValueFloat size l))
    (m, TermEnum _) ->
      returnImmediateS4 m
    (m, TermEnumIntro l) ->
      return (m, CompUpIntro (m, ValueEnumIntro l))
    (m, TermEnumElim (e, _) bs) -> do
      let (cs, es) = unzip bs
      fvs <- constructEnumFVS tenv es
      es' <- (mapM (clarifyTerm tenv) >=> alignFVS tenv m fvs) es
      (y, e', yVar) <- clarifyPlus tenv e
      return $ bindLet [(y, e')] (m, CompEnumElim yVar (zip (map snd cs) es'))
    (m, TermTensor {}) ->
      returnImmediateS4 m -- `tensor`s must be used linearly
    (m, TermTensorIntro es) -> do
      (zs, es', xs) <- unzip3 <$> mapM (clarifyPlus tenv) es
      return $ bindLet (zip zs es') (m, CompUpIntro (m, ValueSigmaIntro xs))
    (m, TermTensorElim xts e1 e2) -> do
      (zName, e1', z) <- clarifyPlus tenv e1
      e2' <- clarifyTerm (insTypeEnv xts tenv) e2
      let (_, xs, _) = unzip3 xts
      return $ bindLet [(zName, e1')] (m, CompSigmaElim xs z e2')
    (m, TermDerangement expKind resultType ekts) -> do
      case (expKind, ekts) of
        (DerangementNop, [(e, _, _)]) ->
          clarifyTerm tenv e
        _ -> do
          let (es, ks, ts) = unzip3 ekts
          xs <- mapM (const $ newNameWith' "sys") es
          let xts = zipWith (\x t -> (fst t, x, t)) xs ts
          let borrowedVarList = catMaybes $ map takeIffLinear (zip xts ks)
          let xsAsVars = map (\(mx, x, _) -> (mx, ValueUpsilon x)) xts
          resultVarName <- newNameWith' "result"
          tuple <- constructResultTuple tenv m borrowedVarList (m, resultVarName, resultType)
          let lamBody = (m, CompUpElim resultVarName (m, CompPrimitive (PrimitiveDerangement expKind xsAsVars)) tuple)
          fvs <- nubFVS <$> chainOf' tenv xts es
          cls <- retClosure tenv Nothing fvs m xts lamBody
          es' <- mapM (clarifyPlus tenv) es
          callClosure m cls es'

clarifyPlus :: TypeEnv -> TermPlus -> WithEnv (Ident, CompPlus, ValuePlus)
clarifyPlus tenv e@(m, _) = do
  e' <- clarifyTerm tenv e
  (varName, var) <- newValueUpsilonWith m "var"
  return (varName, e', var)

clarifyBinder :: TypeEnv -> [IdentPlus] -> WithEnv [(Hint, Ident, CompPlus)]
clarifyBinder tenv binder =
  case binder of
    [] ->
      return []
    ((m, x, t) : xts) -> do
      t' <- clarifyTerm tenv t
      xts' <- clarifyBinder (IntMap.insert (asInt x) t tenv) xts
      return $ (m, x, t') : xts'

constructEnumFVS :: TypeEnv -> [TermPlus] -> WithEnv [IdentPlus]
constructEnumFVS tenv es =
  nubFVS <$> concat <$> mapM (chainOf tenv) es

alignFVS :: TypeEnv -> Hint -> [IdentPlus] -> [CompPlus] -> WithEnv [CompPlus]
alignFVS tenv m fvs es = do
  es' <- mapM (retClosure tenv Nothing fvs m []) es
  mapM (\cls -> callClosure m cls []) es'

nubFVS :: [IdentPlus] -> [IdentPlus]
nubFVS =
  nubBy (\(_, x, _) (_, y, _) -> x == y)

clarifyConst :: TypeEnv -> Hint -> T.Text -> WithEnv CompPlus
clarifyConst tenv m constName
  | Just op <- asPrimOp constName =
    clarifyPrimOp tenv op m
  | Just _ <- asLowTypeMaybe constName =
    returnImmediateS4 m
  | otherwise = do
    cenv <- gets codeEnv
    if Map.member constName cenv
      then return (m, CompUpIntro (m, ValueConst constName))
      else raiseError m $ "undefined constant: " <> constName

clarifyPrimOp :: TypeEnv -> PrimOp -> Hint -> WithEnv CompPlus
clarifyPrimOp tenv op@(PrimOp _ domList _) m = do
  argTypeList <- mapM (lowTypeToType m) domList
  (xs, varList) <- unzip <$> mapM (const (newValueUpsilonWith m "prim")) domList
  let mxts = zipWith (\x t -> (m, x, t)) xs argTypeList
  retClosure tenv Nothing [] m mxts (m, CompPrimitive (PrimitivePrimOp op varList))

takeIffLinear :: (IdentPlus, DerangementArg) -> Maybe IdentPlus
takeIffLinear (xt, k) =
  case k of
    DerangementArgAffine ->
      Nothing
    DerangementArgLinear ->
      Just xt

-- generate tuple like (borrowed-1, ..., borrowed-n, result)
constructResultTuple ::
  TypeEnv ->
  Hint ->
  [IdentPlus] ->
  IdentPlus ->
  WithEnv CompPlus
constructResultTuple tenv m borrowedVarTypeList result@(_, resultVarName, _) =
  if null borrowedVarTypeList
    then return (m, CompUpIntro (m, ValueUpsilon resultVarName))
    else do
      let tupleTypeInfo = borrowedVarTypeList ++ [result]
      tuple <- termSigmaIntro m tupleTypeInfo
      let tenv' = insTypeEnv tupleTypeInfo tenv
      clarifyTerm tenv' tuple

makeClosure ::
  Maybe Ident ->
  [(Hint, Ident, CompPlus)] -> -- list of free variables in `lam (x1, ..., xn). e` (this must be a closed chain)
  Hint -> -- meta of lambda
  [(Hint, Ident, CompPlus)] -> -- the `(x1 : A1, ..., xn : An)` in `lam (x1 : A1, ..., xn : An). e`
  CompPlus -> -- the `e` in `lam (x1, ..., xn). e`
  WithEnv ValuePlus
makeClosure mName mxts2 m mxts1 e = do
  let xts1 = dropFst mxts1
  let xts2 = dropFst mxts2
  envExp <- sigmaS4 Nothing m $ map Right xts2
  let vs = map (\(mx, x, _) -> (mx, ValueUpsilon x)) mxts2
  let fvEnv = (m, ValueSigmaIntro vs)
  case mName of
    Nothing -> do
      i <- newCount
      let name = "thunk-" <> T.pack (show i)
      registerIfNecessary m name False xts1 xts2 e
      return (m, ValueSigmaIntro [envExp, fvEnv, (m, ValueConst name)])
    Just name -> do
      let cls = (m, ValueSigmaIntro [envExp, fvEnv, (m, ValueConst $ asText name <> "_" <> T.pack (show (asInt name)))])
      e' <- substCompPlus (IntMap.fromList [(asInt name, cls)]) IntMap.empty e
      registerIfNecessary m (asText name <> "_" <> T.pack (show (asInt name))) True xts1 xts2 e'
      return cls

registerIfNecessary ::
  Hint ->
  T.Text ->
  Bool ->
  [(Ident, CompPlus)] ->
  [(Ident, CompPlus)] ->
  CompPlus ->
  WithEnv ()
registerIfNecessary m name isFixed xts1 xts2 e = do
  cenv <- gets codeEnv
  when (not $ name `Map.member` cenv) $ do
    e' <- linearize (xts2 ++ xts1) e
    (envVarName, envVar) <- newValueUpsilonWith m "env"
    let args = map fst xts1 ++ [envVarName]
    body <- reduceCompPlus (m, CompSigmaElim (map fst xts2) envVar e')
    insCompEnv name isFixed args body

retClosure ::
  TypeEnv ->
  Maybe Ident -> -- the name of newly created closure
  [IdentPlus] -> -- list of free variables in `lam (x1, ..., xn). e` (this must be a closed chain)
  Hint -> -- meta of lambda
  [IdentPlus] -> -- the `(x1 : A1, ..., xn : An)` in `lam (x1 : A1, ..., xn : An). e`
  CompPlus -> -- the `e` in `lam (x1, ..., xn). e`
  WithEnv CompPlus
retClosure tenv mName fvs m xts e = do
  fvs' <- clarifyBinder tenv fvs
  xts' <- clarifyBinder tenv xts
  cls <- makeClosure mName fvs' m xts' e
  return (m, CompUpIntro cls)

callClosure :: Hint -> CompPlus -> [(Ident, CompPlus, ValuePlus)] -> WithEnv CompPlus
callClosure m e zexes = do
  let (zs, es', xs) = unzip3 zexes
  (clsVarName, clsVar) <- newValueUpsilonWith m "closure"
  typeVarName <- newNameWith' "exp"
  (envVarName, envVar) <- newValueUpsilonWith m "env"
  (lamVarName, lamVar) <- newValueUpsilonWith m "thunk"
  return $
    bindLet
      ((clsVarName, e) : zip zs es')
      ( m,
        CompSigmaElim
          [typeVarName, envVarName, lamVarName]
          clsVar
          (m, CompPiElimDownElim lamVar (xs ++ [envVar]))
      )

chainOf :: TypeEnv -> TermPlus -> WithEnv [IdentPlus]
chainOf tenv term =
  case term of
    (_, TermTau) ->
      return []
    (m, TermUpsilon x) -> do
      t <- lookupTypeEnv m x tenv
      xts <- chainOf tenv t
      senv <- gets substEnv
      if not $ IntMap.member (asInt x) senv
        then return $ xts ++ [(m, x, t)]
        else return $ xts
    (_, TermPi {}) ->
      return []
    (_, TermPiIntro xts e) ->
      chainOf' tenv xts [e]
    (_, TermPiElim e es) -> do
      xs1 <- chainOf tenv e
      xs2 <- concat <$> mapM (chainOf tenv) es
      return $ xs1 ++ xs2
    (_, TermFix (_, x, t) xts e) -> do
      xs1 <- chainOf tenv t
      xs2 <- chainOf' (IntMap.insert (asInt x) t tenv) xts [e]
      return $ xs1 ++ filter (\(_, y, _) -> y /= x) xs2
    (_, TermConst _) ->
      return []
    (_, TermInt _ _) ->
      return []
    (_, TermFloat _ _) ->
      return []
    (_, TermEnum _) ->
      return []
    (_, TermEnumIntro _) ->
      return []
    (_, TermEnumElim (e, t) les) -> do
      xs0 <- chainOf tenv t
      xs1 <- chainOf tenv e
      let es = map snd les
      xs2 <- concat <$> mapM (chainOf tenv) es
      return $ xs0 ++ xs1 ++ xs2
    (_, TermTensor ts) ->
      concat <$> mapM (chainOf tenv) ts
    (_, TermTensorIntro es) ->
      concat <$> mapM (chainOf tenv) es
    (_, TermTensorElim xts e1 e2) -> do
      xs1 <- chainOf tenv e1
      xs2 <- chainOf' tenv xts [e2]
      return $ xs1 ++ xs2
    (_, TermDerangement _ _ ekts) -> do
      let (es, _, ts) = unzip3 ekts
      concat <$> mapM (chainOf tenv) (es ++ ts)

chainOf' :: TypeEnv -> [IdentPlus] -> [TermPlus] -> WithEnv [IdentPlus]
chainOf' tenv binder es =
  case binder of
    [] ->
      concat <$> mapM (chainOf tenv) es
    (_, x, t) : xts -> do
      xs1 <- chainOf tenv t
      xs2 <- chainOf' (IntMap.insert (asInt x) t tenv) xts es
      return $ xs1 ++ filter (\(_, y, _) -> y /= x) xs2

dropFst :: [(a, b, c)] -> [(b, c)]
dropFst xyzs = do
  let (_, ys, zs) = unzip3 xyzs
  zip ys zs

insTypeEnv :: [IdentPlus] -> TypeEnv -> TypeEnv
insTypeEnv xts tenv =
  case xts of
    [] ->
      tenv
    (_, x, t) : rest ->
      insTypeEnv rest $ IntMap.insert (asInt x) t tenv

lookupTypeEnv :: Hint -> Ident -> TypeEnv -> WithEnv TermPlus
lookupTypeEnv m (I (name, x)) tenv =
  case IntMap.lookup x tenv of
    Just t ->
      return t
    Nothing ->
      raiseCritical m $
        "the variable `" <> name <> "` is not found in the type environment."

termSigmaIntro :: Hint -> [IdentPlus] -> WithEnv TermPlus
termSigmaIntro m xts = do
  z <- newNameWith' "internal.sigma-tau-tuple"
  let vz = (m, TermUpsilon z)
  k <- newNameWith'' "sigma"
  let args = map (\(mx, x, _) -> (mx, TermUpsilon x)) xts
  return
    ( m,
      TermPiIntro
        [ (m, z, (m, TermTau)),
          (m, k, (m, TermPi xts vz))
        ]
        (m, TermPiElim (m, TermUpsilon k) args)
    )

toSwitcherBranch :: Hint -> TypeEnv -> TermPlus -> WithEnv (ValuePlus -> WithEnv CompPlus)
toSwitcherBranch m tenv d = do
  d' <- clarifyTerm tenv d
  (varName, var) <- newValueUpsilonWith m "res"
  return $ \val -> callClosure m d' [(varName, (m, CompUpIntro val), var)] >>= reduceCompPlus
