module Entity.Term.Subst (subst) where

import Control.Comonad.Cofree
import Control.Monad
import qualified Data.IntMap as IntMap
import Entity.Binder
import Entity.Global
import qualified Entity.Ident.Reify as Ident
import Entity.LamKind
import Entity.Term

type SubstTerm =
  IntMap.IntMap Term

subst :: SubstTerm -> Term -> IO Term
subst sub term =
  case term of
    (_ :< TermTau) ->
      return term
    (_ :< TermVar x)
      | Just e <- IntMap.lookup (Ident.toInt x) sub ->
        return e
      | otherwise ->
        return term
    (_ :< TermVarGlobal {}) ->
      return term
    (m :< TermPi xts t) -> do
      (xts', t') <- subst' sub xts t
      return (m :< TermPi xts' t')
    (m :< TermPiIntro kind xts e) -> do
      case kind of
        LamKindFix xt -> do
          (xt' : xts', e') <- subst' sub (xt : xts) e
          return (m :< TermPiIntro (LamKindFix xt') xts' e')
        _ -> do
          (xts', e') <- subst' sub xts e
          return (m :< TermPiIntro kind xts' e')
    (m :< TermPiElim e es) -> do
      e' <- subst sub e
      es' <- mapM (subst sub) es
      return (m :< TermPiElim e' es')
    m :< TermSigma xts -> do
      (xts', _) <- subst' sub xts (m :< TermTau)
      return $ m :< TermSigma xts'
    m :< TermSigmaIntro es -> do
      es' <- mapM (subst sub) es
      return $ m :< TermSigmaIntro es'
    m :< TermSigmaElim xts e1 e2 -> do
      e1' <- subst sub e1
      (xts', e2') <- subst' sub xts e2
      return $ m :< TermSigmaElim xts' e1' e2'
    m :< TermLet mxt e1 e2 -> do
      e1' <- subst sub e1
      ([mxt'], e2') <- subst' sub [mxt] e2
      return $ m :< TermLet mxt' e1' e2'
    (_ :< TermConst _) ->
      return term
    (_ :< TermInt {}) ->
      return term
    (_ :< TermFloat {}) ->
      return term
    (_ :< TermEnum _) ->
      return term
    (_ :< TermEnumIntro _) ->
      return term
    (m :< TermEnumElim (e, t) branchList) -> do
      t' <- subst sub t
      e' <- subst sub e
      let (caseList, es) = unzip branchList
      es' <- mapM (subst sub) es
      return (m :< TermEnumElim (e', t') (zip caseList es'))
    (m :< TermMagic der) -> do
      der' <- traverse (subst sub) der
      return (m :< TermMagic der')
    (m :< TermMatch mSubject (e, t) clauseList) -> do
      mSubject' <- mapM (subst sub) mSubject
      e' <- subst sub e
      t' <- subst sub t
      clauseList' <- forM clauseList $ \((mPat, name, xts), body) -> do
        (xts', body') <- subst' sub xts body
        return ((mPat, name, xts'), body')
      return (m :< TermMatch mSubject' (e', t') clauseList')
    m :< TermNoema s e -> do
      s' <- subst sub s
      e' <- subst sub e
      return $ m :< TermNoema s' e'
    m :< TermNoemaIntro s e -> do
      e' <- subst sub e
      return $ m :< TermNoemaIntro s e'
    m :< TermNoemaElim s e -> do
      e' <- subst sub e
      return $ m :< TermNoemaElim s e'
    _ :< TermArray _ ->
      return term
    m :< TermArrayIntro elemType elems -> do
      elems' <- mapM (subst sub) elems
      return $ m :< TermArrayIntro elemType elems'
    m :< TermArrayAccess subject elemType array index -> do
      subject' <- subst sub subject
      array' <- subst sub array
      index' <- subst sub index
      return $ m :< TermArrayAccess subject' elemType array' index'
    _ :< TermText ->
      return term
    _ :< TermTextIntro _ ->
      return term
    m :< TermCell contentType -> do
      contentType' <- subst sub contentType
      return $ m :< TermCell contentType'
    m :< TermCellIntro contentType content -> do
      contentType' <- subst sub contentType
      content' <- subst sub content
      return $ m :< TermCellIntro contentType' content'
    m :< TermCellRead cell -> do
      cell' <- subst sub cell
      return $ m :< TermCellRead cell'
    m :< TermCellWrite cell newValue -> do
      cell' <- subst sub cell
      newValue' <- subst sub newValue
      return $ m :< TermCellWrite cell' newValue'

subst' ::
  SubstTerm ->
  [BinderF Term] ->
  Term ->
  IO ([BinderF Term], Term)
subst' sub binder e =
  case binder of
    [] -> do
      e' <- subst sub e
      return ([], e')
    ((m, x, t) : xts) -> do
      t' <- subst sub t
      x' <- newIdentFromIdent x
      let sub' = IntMap.insert (Ident.toInt x) (m :< TermVar x') sub
      (xts', e') <- subst' sub' xts e
      return ((m, x', t') : xts', e')
