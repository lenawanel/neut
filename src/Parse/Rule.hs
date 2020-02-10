{-# LANGUAGE OverloadedStrings #-}

module Parse.Rule
  ( parseInductive
  , parseCoinductive
  , insForm
  , insInductive
  , insCoinductive
  , internalize
  , externalize
  ) where

import Control.Monad.Except
import Control.Monad.State
import Data.Monoid ((<>))

import qualified Data.HashMap.Strict as Map
import qualified Data.Text as T

import Data.Basic
import Data.Env
import Data.Tree
import Data.WeakTerm
import Parse.Interpret

parseInductive :: [TreePlus] -> WithEnv [Stmt]
parseInductive ts = parseConnective ts toInductive toInductiveIntroList

parseCoinductive :: [TreePlus] -> WithEnv [Stmt]
parseCoinductive ts = parseConnective ts toCoinductive toCoinductiveElimList

-- variable naming convention on parsing connectives:
--   a : the name of a formation rule, like `nat`, `list`, `stream`, etc.
--   b : the name of an introduction/elimination rule, like `zero`, `cons`, `head`, etc.
--   x : the name of an argument of a formation rule, like `A` in `list A` or `stream A`.
--   y : the name of an argument of an introduction/elimination rule, like `w` or `ws` in `cons : Pi (w : A, ws : list A). list A`.
parseConnective ::
     [TreePlus]
  -> ([IdentifierPlus] -> [IdentifierPlus] -> Connective -> WithEnv Stmt)
  -> ([IdentifierPlus] -> Connective -> WithEnv [Stmt])
  -> WithEnv [Stmt]
parseConnective ts f g = do
  connectiveList <- mapM parseConnective' ts
  let ats = map (ruleAsIdentPlus . formationRuleOf) connectiveList
  let bts = concatMap toInternalRuleList connectiveList
  connectiveList' <- mapM (f ats bts) connectiveList
  ruleList <- concat <$> mapM (g ats) connectiveList
  return $ connectiveList' ++ ruleList

parseConnective' :: TreePlus -> WithEnv Connective
parseConnective' (m, TreeNode ((_, TreeAtom name):(_, TreeNode xts):rules)) = do
  m' <- adjustPhase m
  xts' <- mapM interpretIdentifierPlus xts
  rules' <- mapM parseRule rules
  return (m', name, xts', rules')
parseConnective' _ = throwError' "parseConnective: syntax error"

parseRule :: TreePlus -> WithEnv Rule
parseRule (m, TreeNode [(mName, TreeAtom name), (_, TreeNode xts), t]) = do
  m' <- adjustPhase m
  mName' <- adjustPhase mName
  t' <- interpret t
  xts' <- mapM interpretIdentifierPlus xts
  return (m', name, mName', xts', t')
parseRule _ = throwError' "parseRule: syntax error"

-- represent the inductive logical connective within CoC
toInductive ::
     [IdentifierPlus] -> [IdentifierPlus] -> Connective -> WithEnv Stmt
toInductive ats bts connective@(m, a, xts, _) = do
  let formationRule = formationRuleOf connective
  return $
    StmtLetInductive
      (length ats)
      m
      (ruleAsIdentPlus formationRule)
      ( m
      , WeakTermPiIntro
          xts
          ( m
          , WeakTermPi
              (ats ++ bts)
              (m, WeakTermPiElim (m, WeakTermUpsilon a) (map toVar' xts))))

toInductiveIntroList :: [IdentifierPlus] -> Connective -> WithEnv [Stmt]
toInductiveIntroList ats (_, _, xts, rules) = do
  let bts = map ruleAsIdentPlus rules
  mapM (toInductiveIntro ats bts xts) rules

-- represent the introduction rule within CoC
toInductiveIntro ::
     [IdentifierPlus]
  -> [IdentifierPlus]
  -> [IdentifierPlus]
  -> Rule
  -> WithEnv Stmt
toInductiveIntro ats bts xts (mb, b, m, yts, cod) = do
  return $
    StmtLetInductiveIntro
      m
      (mb, b, (m, WeakTermPi (xts ++ yts) cod))
      xts
      yts
      ats
      bts
      (mb, WeakTermUpsilon b)
      -- yts
      []
      (map (\(_, a, _) -> a) ats)

-- -- represent the coinductive logical connective within CoC
toCoinductive ::
     [IdentifierPlus] -> [IdentifierPlus] -> Connective -> WithEnv Stmt
toCoinductive ats bts c@(m, a, xts, _) = do
  let cod = (m, WeakTermPiElim (m, WeakTermUpsilon a) (map toVar' xts))
  let f = formationRuleOf c
  h <- newNameWith "cod"
  return $
    StmtLet
      m
      (ruleAsIdentPlus f) -- a : Pi xts. Univ
      (m, WeakTermPiIntro xts (m, WeakTermSigma (ats ++ bts ++ [(m, h, cod)])))

toCoinductiveElimList :: [IdentifierPlus] -> Connective -> WithEnv [Stmt]
toCoinductiveElimList ats (_, _, xts, rules) = do
  let bts = map ruleAsIdentPlus rules
  mapM (toCoinductiveElim ats bts xts) rules

-- represent the elimination rule within CoC
toCoinductiveElim ::
     [IdentifierPlus]
  -> [IdentifierPlus]
  -> [IdentifierPlus]
  -> Rule
  -> WithEnv Stmt
toCoinductiveElim ats bts xts (mb, b, m, yts, cod)
  | [yt] <- yts = do
    return $
      StmtLetCoinductiveElim
        m
        (mb, b, (m, WeakTermPi (xts ++ [yt]) cod))
        (xts ++ [yt])
        cod
        ats
        bts
        yt
        (toVar' yt)
        (m, WeakTermPiElim (mb, WeakTermUpsilon b) [toVar' yt])
        []
        (map (\(_, a, _) -> a) ats)
  | otherwise = throwError' "toCoinductiveElim"

ruleAsIdentPlus :: Rule -> IdentifierPlus
ruleAsIdentPlus (mb, b, m, xts, t) = (mb, b, (m, WeakTermPi xts t))

formationRuleOf :: Connective -> Rule
formationRuleOf (m, a, xts, _) = (m, a, m, xts, (m, WeakTermTau))

toInternalRuleList :: Connective -> [IdentifierPlus]
toInternalRuleList (_, _, _, rules) = map ruleAsIdentPlus rules

toVar' :: IdentifierPlus -> WeakTermPlus
toVar' (m, x, _) = (m, WeakTermUpsilon x)

insForm :: Int -> IdentifierPlus -> WeakTermPlus -> WithEnv ()
insForm 1 (_, a, _) e =
  modify (\env -> env {formationEnv = Map.insert a (Just e) (formationEnv env)})
insForm _ (_, a, _) _ =
  modify (\env -> env {formationEnv = Map.insert a Nothing (formationEnv env)})

insInductive :: [Identifier] -> IdentifierPlus -> WithEnv ()
insInductive [a] bt = do
  ienv <- gets inductiveEnv
  modify
    (\env -> env {inductiveEnv = Map.insertWith optConcat a (Just [bt]) ienv})
insInductive as _ = do
  forM_ as $ \a -> do
    modify
      (\env -> env {inductiveEnv = Map.insert a Nothing (inductiveEnv env)})

insCoinductive :: [Identifier] -> IdentifierPlus -> WithEnv ()
insCoinductive [a] bt = do
  cenv <- gets coinductiveEnv
  modify
    (\env -> env {coinductiveEnv = Map.insertWith optConcat a (Just [bt]) cenv})
insCoinductive as _ = do
  forM_ as $ \a -> do
    modify
      (\env -> env {coinductiveEnv = Map.insert a Nothing (coinductiveEnv env)})

optConcat :: Maybe [a] -> Maybe [a] -> Maybe [a]
optConcat mNew mOld = do
  mNew' <- mNew
  mOld' <- mOld
  -- insert mNew at the end of the list (to respect the structure of ind/coind represented as pi/sigma)
  return $ mOld' ++ mNew'

-- ここでモジュールを切るべき？
data Mode
  = ModeInternalize
  | ModeExternalize
  deriving (Show)

internalize ::
     SubstWeakTerm -> [IdentifierPlus] -> IdentifierPlus -> WithEnv WeakTermPlus
internalize isub atsbts (m, y, t) =
  zeta ModeInternalize isub [] atsbts t (m, WeakTermUpsilon y)

externalize ::
     SubstWeakTerm
  -> [IdentifierPlus]
  -> WeakTermPlus
  -> WeakTermPlus
  -> WithEnv WeakTermPlus
externalize csub atsbts t e = zeta ModeExternalize [] csub atsbts t e

flipMode :: Mode -> Mode
flipMode ModeInternalize = ModeExternalize
flipMode ModeExternalize = ModeInternalize

isResolved :: SubstWeakTerm -> WeakTermPlus -> Bool
isResolved sub e = do
  let xs = map fst sub
  let ys = varWeakTermPlus e
  all (\x -> x `notElem` ys) xs

zeta ::
     Mode -- 現在の変換がinvertedかそうでないかをtrackするための変数（となるようにあとで修正すること）
  -> SubstWeakTerm -- out ~> in (substitution {x1 := x1', ..., xn := xn'})
  -> SubstWeakTerm -- in ~> out
  -> [IdentifierPlus] -- ats ++ bts
  -> WeakTermPlus -- a type `A`
  -> WeakTermPlus -- a term `e` of type `A`
  -> WithEnv WeakTermPlus -- a term of type `A{x1 := x1', ..., xn := xn'}`
zeta mode isub csub atsbts t e = do
  ienv <- gets inductiveEnv
  cenv <- gets coinductiveEnv
  isub' <- invSubst isub
  csub' <- invSubst csub
  case t of
    (_, WeakTermPi xts cod) -> zetaPi mode isub csub atsbts xts cod e
      -- (_, WeakTermSigma _) -> undefined
    (_, WeakTermPiElim va@(_, WeakTermUpsilon a) es)
      | Just _ <- lookup a (isub ++ isub') ->
        zetaInductive mode isub atsbts es e
      | Just _ <- lookup a (csub ++ csub') ->
        zetaCoinductive mode csub atsbts es e va
      | Just (Just bts) <- Map.lookup a ienv
      , not (all (isResolved (isub ++ csub)) es) ->
        zetaInductiveNested mode isub csub atsbts e va a es bts
      | Just (Just bts) <- Map.lookup a cenv
      , not (all (isResolved (isub ++ csub)) es) ->
        zetaCoinductiveNested mode isub csub atsbts e va a es bts
      | Just Nothing <- Map.lookup a ienv -> zetaInductiveNestedMutual a
      | Just Nothing <- Map.lookup a cenv -> zetaCoinductiveNestedMutual a
    _ -> do
      if isResolved (isub ++ csub) t
        then return e
        else throwError' $
             "malformed inductive/coinductive type definition: " <>
             T.pack (show t)

zetaPi ::
     Mode
  -> SubstWeakTerm
  -> SubstWeakTerm
  -> [IdentifierPlus]
  -> [IdentifierPlus]
  -> WeakTermPlus
  -> WeakTermPlus
  -> WithEnv WeakTermPlus
zetaPi mode isub csub atsbts xts cod e = do
  p "===========zetaPi========="
  let (ms, xs, ts) = unzip3 xts
  xs' <- mapM newNameWith xs
  let vs' = zipWith (\m x -> (m, WeakTermUpsilon x)) ms xs'
  -- backward conversion to create (A', ..., A') -> (A, ..., A)
  isub' <- invSubst isub
  csub' <- invSubst csub
  vs <- zipWithM (zeta (flipMode mode) isub' csub' atsbts) ts vs'
  -- forward conversion to create B -> B'
  app' <- zeta mode isub csub atsbts cod (fst e, WeakTermPiElim e vs)
  -- return (A' ..., A') -> (A, ..., A) -> B -> B'
  let ts' = map (substWeakTermPlus (isub ++ csub)) ts
  return $ (fst e, WeakTermPiIntro (zip3 ms xs' ts') app')

zetaInductive ::
     Mode
  -> SubstWeakTerm
  -> [IdentifierPlus]
  -> [WeakTermPlus]
  -> WeakTermPlus
  -> WithEnv WeakTermPlus
zetaInductive mode isub atsbts es e
  | ModeExternalize <- mode =
    throwError' "found a contravariant occurence of an inductive type"
  | all (isResolved isub) es = do
    return (fst e, WeakTermPiElim e (map toVar' atsbts))
  | otherwise = throwError' "found a self-nested inductive type"

zetaCoinductive ::
     Mode
  -> SubstWeakTerm
  -> [IdentifierPlus]
  -> [WeakTermPlus]
  -> WeakTermPlus
  -> WeakTermPlus
  -> WithEnv WeakTermPlus
zetaCoinductive mode csub atsbts es e va
  | ModeInternalize <- mode =
    throwError' "found a contravariant occurrence of a coinductive type"
  | all (isResolved csub) es = do
    let es' = map (substWeakTermPlus csub) es
    let t' = (fst va, WeakTermPiElim va es')
    return (fst e, WeakTermSigmaIntro t' (map toVar' atsbts ++ [e]))
  | otherwise = throwError' "found a self-nested coinductive type"

-- atsbtsは、internalizeで使用するためのもの
-- eは引数で、translateの対象
-- list @ (item A)とかのとき、vaにlistがきて、esに[list A]がくる。
-- btsは既に定義済みのコンストラクタ定義の集合。
zetaInductiveNested ::
     Mode
  -> SubstWeakTerm -- inductiveのためのaのsubst (outer -> inner)
  -> SubstWeakTerm -- coinductiveのためのaのsubst (inner -> outer)
  -> [IdentifierPlus] -- innerのためのatsbts
  -> WeakTermPlus -- 変換されるべきterm
  -> WeakTermPlus -- list Aにおけるlist
  -> Identifier -- list (トップレベルで定義されている名前、つまりouterの名前)
  -> [WeakTermPlus] -- list AにおけるA
  -> [IdentifierPlus] -- トップレベルで定義されているコンストラクタたち
  -> WithEnv WeakTermPlus
zetaInductiveNested mode isub csub atsbts e va aOuter es bts = do
  (xts, (_, aInner, _), btsInner) <- lookupInductive aOuter
  let es' = map (substWeakTermPlus (isub ++ csub)) es
  args <-
    zipWithM
      (toInternalizedArg mode isub csub aInner aOuter xts atsbts es es')
      bts
      btsInner
  let m = fst e
  return
    ( m
    , WeakTermPiElim
        e
        ((m, WeakTermPiIntro xts (m, WeakTermPiElim va es')) : args))

zetaCoinductiveNested ::
     Mode
  -> SubstWeakTerm
  -> SubstWeakTerm
  -> [IdentifierPlus]
  -> WeakTermPlus
  -> WeakTermPlus
  -> Identifier
  -> [WeakTermPlus]
  -> [IdentifierPlus]
  -> WithEnv WeakTermPlus
zetaCoinductiveNested mode isub csub atsbts e va a es bts = do
  (xts, btsInner) <- lookupCoinductive a
  let es' = map (substWeakTermPlus (isub ++ csub)) es
  a' <- newNameWith "zeta"
  args <-
    zipWithM
      (toExternalizedArg mode isub csub a a' xts atsbts es es')
      bts
      btsInner
  let m = fst e
  return
    ( m
    , WeakTermPiElim
        ( m
        , WeakTermPiIntro
            [(m, a', (m, WeakTermPi xts (m, WeakTermTau)))]
            ( m
            , WeakTermSigmaIntro
                (fst e, WeakTermPiElim va es')
                ((m, WeakTermUpsilon a') : args ++ [e])))
        [(m, WeakTermPiIntro xts (m, WeakTermPiElim va es'))])

zetaInductiveNestedMutual :: Identifier -> WithEnv WeakTermPlus
zetaInductiveNestedMutual a =
  throwError' $
  "mutual inductive type `" <>
  a <> "` cannot be used to construct a nested inductive type"

zetaCoinductiveNestedMutual :: Identifier -> WithEnv WeakTermPlus
zetaCoinductiveNestedMutual a =
  throwError' $
  "mutual coinductive type `" <>
  a <> "` cannot be used to construct a nested coinductive type"

lookupInductive ::
     Identifier -> WithEnv ([IdentifierPlus], IdentifierPlus, [IdentifierPlus])
lookupInductive a = do
  fenv <- gets formationEnv
  case Map.lookup a fenv of
    Just (Just (_, WeakTermPiIntro xts (_, WeakTermPi atsbts (_, WeakTermPiElim (_, WeakTermUpsilon _) _)))) -> do
      let at = head atsbts
      let bts = tail atsbts -- valid since a is not mutual
      return (xts, at, bts)
    Just (Just _) ->
      throwError' $
      "[compiler bug] malformed inductive type (Parse.lookupInductive)"
    Just Nothing ->
      throwError' $
      "the inductive type `" <> a <> "` must be a non-mutual inductive type"
    Nothing ->
      throwError' $ "[compiler bug] no such inductive type defined: " <> a

lookupCoinductive :: Identifier -> WithEnv ([IdentifierPlus], [IdentifierPlus])
lookupCoinductive a = do
  fenv <- gets formationEnv
  case Map.lookup a fenv of
    Just (Just (_, WeakTermPiIntro xts (_, WeakTermSigma atsbtscod))) -> do
      let bts = init $ tail atsbtscod -- valid since a is not mutual
      return (xts, bts)
    Just (Just _) ->
      throwError' $
      "[compiler bug] malformed coinductive type (Parse.lookupCoinductive)"
    Just Nothing ->
      throwError' $
      "the coinductive type `" <> a <> "` must be a non-mutual coinductive type"
    Nothing ->
      throwError' $ "[compiler bug] no such coinductive type defined: " <> a

toInternalizedArg ::
     Mode
  -> SubstWeakTerm -- inductiveのためのaのsubst (outer -> inner)
  -> SubstWeakTerm -- coinductiveのためのaのsubst (inner -> outer)
  -> Identifier -- innerでのaの名前。listの定義の中に出てくるほうのlist.
  -> Identifier -- outerでのaの名前。listとか。
  -> [IdentifierPlus] -- aの引数。
  -> [IdentifierPlus] -- base caseでのinternalizeのための情報。
  -> [WeakTermPlus] -- list @ (e1, ..., en)の引数部分。
  -> [WeakTermPlus] -- eiをisub ++ csubでsubstしたもの。
  -> IdentifierPlus -- outerでのコンストラクタ。
  -> IdentifierPlus -- innerでのコンストラクタ。xts部分の引数だけouterのコンストラクタと型がずれていることに注意。
  -> WithEnv WeakTermPlus
toInternalizedArg mode isub csub aInner aOuter xts atsbts es es' b (mbInner, _, (_, WeakTermPi ytsInner _)) = do
  let (ms, ys, ts) = unzip3 ytsInner
  let vxs = map toVar' xts
  -- 引数の型を適切にsubstする。これによって、aInner (x1, ..., xn)の出現がaOuter (e1', ..., en')へと置き換えられて、
  -- 結果的にaOuterの中身はすべて処理済みとなる。
  -- ytsInnerはPiの内部でのコンストラクタの型であるから、substをするときはaInnerからsubstを行なう必要がある。……本当か？
  -- このsubstを行なうことで結局z @ (aOuter, ARGS)のARGS部分の引数がaOuter関連のもので揃うから正しいはず。
  ts' <- mapM (substRuleType ((aInner, vxs), (aOuter, es'))) ts
  -- aInner (x1, ..., xn) ~> aOuter (e1', ..., en')が終わったら、こんどは型のxiをeiに置き換える。
  -- これによって、
  --   - aOuterの中身はすべて処理済み
  --   - aOuterの外にはeiが出現しうる
  -- という状況が実現できる。これはrecursionの停止を与える。
  let xs = map (\(_, x, _) -> x) xts
  let ts'' = map (substWeakTermPlus (zip xs es)) ts'
  ys' <- mapM newNameWith ys
  -- これで引数の型の調整が終わったので、あらためてidentPlusの形に整える
  -- もしかしたらyって名前を別名に変更したほうがいいかもしれないが。
  -- let ytsInner' = zip3 ms ys ts''
  let ytsInner' = zip3 ms ys' ts''
  -- 引数をコンストラクタに渡せるようにするために再帰的にinternalizeをおこなう。
  -- list (item-outer A)みたいな形だったものは、list (item-inner A)となっているはずなので、zetaは停止する。
  -- list (list (item-outer A))みたいな形だったものも、list (list (item-inner A))となってzetaは停止する。
  let f (m, y, t) = zeta mode isub csub atsbts t (m, WeakTermUpsilon y)
  args <- mapM f ytsInner'
  -- あとは結果を返すだけ
  return
    ( mbInner
    , WeakTermPiIntro
        ytsInner'
        (mbInner, WeakTermPiElim (toVar' b) (es' ++ args)))
toInternalizedArg _ _ _ _ _ _ _ _ _ _ _ = throwError' "toInternalizedArg"

toExternalizedArg ::
     Mode
  -> SubstWeakTerm
  -> SubstWeakTerm
  -> Identifier
  -> Identifier
  -> [IdentifierPlus]
  -> [IdentifierPlus]
  -> [WeakTermPlus]
  -> [WeakTermPlus]
  -> IdentifierPlus
  -> IdentifierPlus
  -> WithEnv WeakTermPlus
toExternalizedArg mode isub csub a a' xts atsbts es es' b (mbInner, _, (_, WeakTermPi yts cod)) = do
  let (ms, ys, ts) = unzip3 yts
  let vxs = map toVar' xts
  ts' <- mapM (modifyType isub ((a, vxs), (a', es'))) ts
  let xs = map (\(_, x, _) -> x) xts
  let yts' = zip3 ms ys ts'
  let app = (mbInner, WeakTermPiElim (toVar' b) (es' ++ (map toVar' yts)))
  cod' <- modifyType csub ((a, vxs), (a', es')) cod
  -- a'の中身はe', a'の外はe
  let cod'' = substWeakTermPlus (zip xs es) cod'
  app' <- zeta mode isub csub atsbts cod'' app
  return (mbInner, WeakTermPiIntro yts' app')
toExternalizedArg _ _ _ _ _ _ _ _ _ _ _ = throwError' "toExternalizedArg"

type RuleType = (Identifier, [WeakTermPlus])

modifyType ::
     SubstWeakTerm
  -> (RuleType, RuleType) -- ((a, [x1, ..., xn]), (a', [e1', ..., en']))
  -> WeakTermPlus -- subst対象の型
  -> WithEnv WeakTermPlus -- subst結果
modifyType sub rsub t = do
  t' <- substRuleType rsub t -- これでaの中には処理済みのものしか出現しない
  return $ substWeakTermPlus sub t' -- aの外側を処理

substRuleType :: (RuleType, RuleType) -> WeakTermPlus -> WithEnv WeakTermPlus
substRuleType _ (m, WeakTermTau) = return (m, WeakTermTau)
substRuleType sub (m, WeakTermUpsilon x) =
  if fst (fst sub) == x
    then throwError' "invalid use of inductive/coinductive type"
    else return (m, WeakTermUpsilon x)
substRuleType sub (m, WeakTermPi xts t) = do
  (xts', t') <- substRuleTypeBindingsWithBody sub xts t
  return (m, WeakTermPi xts' t')
substRuleType sub (m, WeakTermPiIntro xts body) = do
  (xts', body') <- substRuleTypeBindingsWithBody sub xts body
  return (m, WeakTermPiIntro xts' body')
substRuleType sub@((a1, es1), (a2, es2)) (m, WeakTermPiElim e es)
  | (mx, WeakTermUpsilon x) <- e
  , a1 == x =
    case (mapM asUpsilon es1, mapM asUpsilon es) of
      (Just xs', Just ys')
        | xs' == ys' -> return (m, WeakTermPiElim (mx, WeakTermUpsilon a2) es2)
      (_, _) ->
        throwError'
          "generalized inductive/coinductive type cannot be used to construct a nested inductive/coinductive type"
  | otherwise = do
    e' <- substRuleType sub e
    es' <- mapM (substRuleType sub) es
    return (m, WeakTermPiElim e' es')
substRuleType sub (m, WeakTermSigma xts) = do
  xts' <- substRuleTypeBindings sub xts
  return (m, WeakTermSigma xts')
substRuleType sub (m, WeakTermSigmaIntro t es) = do
  t' <- substRuleType sub t
  es' <- mapM (substRuleType sub) es
  return (m, WeakTermSigmaIntro t' es')
substRuleType sub (m, WeakTermSigmaElim t xts e1 e2) = do
  t' <- substRuleType sub t
  e1' <- substRuleType sub e1
  (xts', e2') <- substRuleTypeBindingsWithBody sub xts e2
  return (m, WeakTermSigmaElim t' xts' e1' e2')
substRuleType sub (m, WeakTermIter (mx, x, t) xts e) = do
  t' <- substRuleType sub t
  if fst (fst sub) == x
    then return (m, WeakTermIter (mx, x, t') xts e)
    else do
      (xts', e') <- substRuleTypeBindingsWithBody sub xts e
      return (m, WeakTermIter (mx, x, t') xts' e')
substRuleType _ (m, WeakTermConst x) = return (m, WeakTermConst x)
substRuleType sub (m, WeakTermConstDecl (mx, x, t) e) = do
  t' <- substRuleType sub t
  if fst (fst sub) == x
    then return (m, WeakTermConstDecl (mx, x, t') e)
    else do
      e' <- substRuleType sub e
      return (m, WeakTermConstDecl (mx, x, t') e')
substRuleType _ (m, WeakTermZeta x) = return (m, WeakTermZeta x)
substRuleType sub (m, WeakTermInt t x) = do
  t' <- substRuleType sub t
  return (m, WeakTermInt t' x)
substRuleType _ (m, WeakTermFloat16 x) = do
  return (m, WeakTermFloat16 x)
substRuleType _ (m, WeakTermFloat32 x) = do
  return (m, WeakTermFloat32 x)
substRuleType _ (m, WeakTermFloat64 x) = do
  return (m, WeakTermFloat64 x)
substRuleType sub (m, WeakTermFloat t x) = do
  t' <- substRuleType sub t
  return (m, WeakTermFloat t' x)
substRuleType _ (m, WeakTermEnum x) = return (m, WeakTermEnum x)
substRuleType _ (m, WeakTermEnumIntro l) = return (m, WeakTermEnumIntro l)
substRuleType sub (m, WeakTermEnumElim (e, t) branchList) = do
  t' <- substRuleType sub t
  e' <- substRuleType sub e
  let (caseList, es) = unzip branchList
  es' <- mapM (substRuleType sub) es
  return (m, WeakTermEnumElim (e', t') (zip caseList es'))
substRuleType sub (m, WeakTermArray dom k) = do
  dom' <- substRuleType sub dom
  return (m, WeakTermArray dom' k)
substRuleType sub (m, WeakTermArrayIntro k es) = do
  es' <- mapM (substRuleType sub) es
  return (m, WeakTermArrayIntro k es')
substRuleType sub (m, WeakTermArrayElim mk xts v e) = do
  v' <- substRuleType sub v
  (xts', e') <- substRuleTypeBindingsWithBody sub xts e
  return (m, WeakTermArrayElim mk xts' v' e')
substRuleType _ (m, WeakTermStruct ts) = return (m, WeakTermStruct ts)
substRuleType sub (m, WeakTermStructIntro ets) = do
  let (es, ts) = unzip ets
  es' <- mapM (substRuleType sub) es
  return (m, WeakTermStructIntro $ zip es' ts)
substRuleType sub (m, WeakTermStructElim xts v e) = do
  v' <- substRuleType sub v
  let xs = map (\(_, x, _) -> x) xts
  if fst (fst sub) `elem` xs
    then return (m, WeakTermStructElim xts v' e)
    else do
      e' <- substRuleType sub e
      return (m, WeakTermStructElim xts v' e')

substRuleTypeBindings ::
     (RuleType, RuleType) -> [IdentifierPlus] -> WithEnv [IdentifierPlus]
substRuleTypeBindings _ [] = return []
substRuleTypeBindings sub ((m, x, t):xts) = do
  t' <- substRuleType sub t
  if fst (fst sub) == x
    then return $ (m, x, t') : xts
    else do
      xts' <- substRuleTypeBindings sub xts
      return $ (m, x, t') : xts'

substRuleTypeBindingsWithBody ::
     (RuleType, RuleType)
  -> [IdentifierPlus]
  -> WeakTermPlus
  -> WithEnv ([IdentifierPlus], WeakTermPlus)
substRuleTypeBindingsWithBody sub [] e = do
  e' <- substRuleType sub e
  return ([], e')
substRuleTypeBindingsWithBody sub ((m, x, t):xts) e = do
  t' <- substRuleType sub t
  if fst (fst sub) == x
    then return ((m, x, t') : xts, e)
    else do
      (xts', e') <- substRuleTypeBindingsWithBody sub xts e
      return ((m, x, t') : xts', e')

invSubst :: SubstWeakTerm -> WithEnv SubstWeakTerm
invSubst [] = return []
invSubst ((x, (m, WeakTermUpsilon x')):sub) = do
  sub' <- invSubst sub
  return $ (x', (m, WeakTermUpsilon x)) : sub'
invSubst _ = throwError' "invSubst"
