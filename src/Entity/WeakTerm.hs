module Entity.WeakTerm where

import Control.Comonad.Cofree
import qualified Data.IntMap as IntMap
import Entity.Arity
import Entity.Binder
import qualified Entity.DefiniteDescription as DD
import Entity.EnumCase
import Entity.EnumTypeName
import Entity.Hint
import Entity.HoleID
import Entity.Ident
import Entity.LamKind
import Entity.Magic
import Entity.Pattern
import qualified Entity.Prim as Prim
import Entity.PrimNum
import Entity.PrimNumSize

type WeakTerm = Cofree WeakTermF Hint

data WeakTermF a
  = Tau
  | Var Ident
  | VarGlobal DD.DefiniteDescription Arity
  | Pi [BinderF a] a
  | PiIntro (LamKindF a) [BinderF a] a
  | PiElim a [a]
  | Sigma [BinderF a]
  | SigmaIntro [a]
  | SigmaElim [BinderF a] a a
  | Let (BinderF a) a a -- let x = e1 in e2 (with no context extension)
  | Aster HoleID [WeakTerm] -- ?M @ (e1, ..., en)
  | Prim Prim.Prim
  | Int a Integer
  | Float a Double
  | Enum EnumTypeName
  | EnumIntro EnumLabel
  | EnumElim (a, a) [(EnumCase, a)]
  | Question a a -- e : t (output the type `t` as note)
  | Magic (Magic a) -- (magic kind arg-1 ... arg-n)
  | Match (a, a) [(PatternF a, a)] -- (pattern-matched value, its type) [(pattern, body)]

type SubstWeakTerm =
  IntMap.IntMap WeakTerm

toVar :: Hint -> Ident -> WeakTerm
toVar m x =
  m :< Var x

i8 :: Hint -> WeakTerm
i8 m =
  m :< Prim (Prim.Type $ PrimNumInt $ IntSize 8)

i64 :: Hint -> WeakTerm
i64 m =
  m :< Prim (Prim.Type $ PrimNumInt $ IntSize 64)

metaOf :: WeakTerm -> Hint
metaOf (m :< _) =
  m

asVar :: WeakTerm -> Maybe Ident
asVar term =
  case term of
    (_ :< Var x) ->
      Just x
    _ ->
      Nothing
