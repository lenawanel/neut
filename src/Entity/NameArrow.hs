module Entity.NameArrow
  ( RawNameArrow (..),
    NameArrow,
    InnerRawNameArrow,
    reify,
  )
where

import Entity.DefiniteDescription qualified as DD
import Entity.GlobalName qualified as GN
import Entity.Hint
import Entity.VarOrLocator
import GHC.Generics

type NameArrow =
  (NameArrowDom, NameArrowCod)

type NameArrowDom =
  (Hint, DD.DefiniteDescription)

type NameArrowCod =
  (Hint, GN.GlobalName)

data RawNameArrow
  = Function InnerRawNameArrow
  | Variant
      InnerRawNameArrow -- original name
      [InnerRawNameArrow] -- arrows for constructors/destructors
  deriving (Generic)

type RawNameArrowCod =
  (Hint, VarOrLocator)

type InnerRawNameArrow =
  (NameArrowDom, RawNameArrowCod)

reify :: NameArrow -> (DD.DefiniteDescription, GN.GlobalName)
reify ((_, aliasName), (_, origDD)) = do
  (aliasName, origDD)
