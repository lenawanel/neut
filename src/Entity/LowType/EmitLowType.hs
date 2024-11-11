module Entity.LowType.EmitLowType where

import Data.ByteString.Builder
import Entity.Arch qualified as A
import Entity.Builder
import Entity.LowType qualified as LT
import Entity.PrimNumSize (IntSize (IntSize))
import Entity.PrimType qualified as PT
import Entity.PrimType.EmitPrimType

emitLowType :: LT.LowType -> Builder
emitLowType lowType =
  case lowType of
    LT.PrimNum primType ->
      emitPrimType primType
    LT.Struct ts ->
      "{" <> unwordsC (map emitLowType ts) <> "}"
    LT.Function ts t ->
      emitLowType t <> " (" <> unwordsC (map emitLowType ts) <> ")"
    LT.Array i t -> do
      "[" <> intDec i <> " x " <> emitLowType t <> "]"
    LT.Pointer ->
      "ptr"
    LT.Void ->
      "void"
    LT.VarArgs ->
      "..."
    LT.Word arch ->
      case arch of
        A.Amd64 ->
          emitLowType $ LT.PrimNum $ PT.Int $ IntSize 64
        A.Arm64 ->
          emitLowType $ LT.PrimNum $ PT.Int $ IntSize 64
