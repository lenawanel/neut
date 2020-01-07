module Data.Basic where

import Data.Bits
import Data.Maybe (fromMaybe)
import Text.Read

type Identifier = String

type Loc = (Int, Int)

data Case
  = CaseValue EnumValue
  | CaseDefault
  deriving (Show, Eq, Ord)

data EnumType
  = EnumTypeLabel Identifier
  | EnumTypeNatNum Integer
  deriving (Show, Eq)

data Meta =
  Meta
    { metaFileName :: Maybe String
    , metaLocation :: Maybe Loc
    }

-- required to derive the eqality on WeakTerm
instance Eq Meta where
  _ == _ = True

instance Show Meta where
  show _ = "_"

emptyMeta :: Meta
emptyMeta = Meta {metaLocation = Nothing, metaFileName = Nothing}

readNatEnumType :: Identifier -> (Maybe Integer)
readNatEnumType str -- n1, n2, ..., n{i}, ..., n{2^64}
  | length str >= 2
  , head str == 'n'
  , Just i <- readMaybe (tail str)
  , 1 <= i && i <= 2 ^ (64 :: Integer) = Just i
readNatEnumType _ = Nothing

readNatEnumValue :: Identifier -> (Maybe (Integer, Integer))
readNatEnumValue str -- n1-0, n2-0, n2-1, ...
  | length str >= 4
  , head str == 'n'
  , [iStr, jStr] <- wordsBy '-' (tail str)
  , Just i <- readMaybe iStr
  , 1 <= i && i <= 2 ^ (64 :: Integer)
  , Just j <- readMaybe jStr
  , 0 <= j && j <= i - 1 = Just (i, j)
readNatEnumValue _ = Nothing

asEnumNatNumConstant :: Identifier -> Maybe Integer
asEnumNatNumConstant x
  | length x >= 7 -- length "enum.n4" == 7
  , ["enum", y] <- wordsBy '.' x
  , Just i <- readNatEnumType y = Just i -- enum.n{i} is a constant
asEnumNatNumConstant _ = Nothing

isConstant :: Identifier -> Bool
isConstant x
  | Just _ <- asEnumNatNumConstant x = True
  | Just _ <- asLowTypeMaybe x = True
  | Just _ <- asUnaryOpMaybe x = True
  | Just _ <- asBinaryOpMaybe x = True
  | otherwise = False

data EnumValue
  = EnumValueLabel Identifier
  | EnumValueNatNum Integer Integer
  deriving (Show, Eq, Ord)

data LowType
  = LowTypeIntS IntSize
  | LowTypeIntU IntSize
  | LowTypeFloat FloatSize
  | LowTypeVoidPtr
  | LowTypeFunctionPtr [LowType] LowType
  | LowTypeStructPtr [LowType]
  | LowTypeArrayPtr Integer LowType -- [n x LOWTYPE]*
  | LowTypeIntS64Ptr
  deriving (Eq, Show)

type IntSize = Integer

asIntS :: Integral a => a -> a -> a
asIntS size n = do
  let upperBound = 2 ^ (size - 1)
  let m = 2 * upperBound
  let a = mod n m
  if a >= upperBound
    then a - m
    else a

asIntU :: Integral a => a -> a -> a
asIntU size n = mod n (2 ^ size)

data FloatSize
  = FloatSize16
  | FloatSize32
  | FloatSize64
  deriving (Eq, Show)

sizeAsInt :: FloatSize -> Integer
sizeAsInt FloatSize16 = 16
sizeAsInt FloatSize32 = 32
sizeAsInt FloatSize64 = 64

data ArrayKind
  = ArrayKindIntS Integer
  | ArrayKindIntU Integer
  | ArrayKindFloat FloatSize
  deriving (Show, Eq)

asArrayKind :: LowType -> Maybe ArrayKind
asArrayKind (LowTypeIntS i) = Just $ ArrayKindIntS i
asArrayKind (LowTypeIntU i) = Just $ ArrayKindIntU i
asArrayKind (LowTypeFloat size) = Just $ ArrayKindFloat size
asArrayKind _ = Nothing

arrayKindToLowType :: ArrayKind -> LowType
arrayKindToLowType (ArrayKindIntS i) = LowTypeIntS i
arrayKindToLowType (ArrayKindIntU i) = LowTypeIntU i
arrayKindToLowType (ArrayKindFloat size) = LowTypeFloat size

voidPtr :: LowType
voidPtr = LowTypeVoidPtr

data UnaryOp
  = UnaryOpNeg -- fneg
  | UnaryOpTrunc LowType -- trunc, fptrunc
  | UnaryOpZext LowType -- zext
  | UnaryOpSext LowType -- sext
  | UnaryOpFpExt LowType -- fpext
  | UnaryOpTo LowType -- fp-to-ui, fp-to-si, ui-to-fp, si-to-fp (f32.to.i32, i32.to.f64, etc.)
  deriving (Eq, Show)

data BinaryOp
  = BinaryOpAdd
  | BinaryOpSub
  | BinaryOpMul
  | BinaryOpDiv
  | BinaryOpRem
  | BinaryOpEQ
  | BinaryOpNE
  | BinaryOpGT
  | BinaryOpGE
  | BinaryOpLT
  | BinaryOpLE
  | BinaryOpShl
  | BinaryOpLshr
  | BinaryOpAshr
  | BinaryOpAnd
  | BinaryOpOr
  | BinaryOpXor
  deriving (Eq, Show)

data SysCall =
  SysCallWrite
  deriving (Eq, Show)

type ArgLen = Int

type UsedArgIndexList = [Int]

type Target = (OS, Arch)

data OS
  = OSLinux
  | OSDarwin
  deriving (Eq, Show)

data Arch =
  Arch64
  deriving (Eq, Show)

showItems :: (a -> String) -> [a] -> String
showItems _ [] = ""
showItems f [a] = f a
showItems f (a:as) = f a ++ ", " ++ showItems f as

asLowType :: Identifier -> LowType
asLowType n = fromMaybe (LowTypeIntS 64) (asLowTypeMaybe n)

asLowTypeMaybe :: Identifier -> Maybe LowType
asLowTypeMaybe ('i':cs)
  | Just n <- readMaybe cs
  , 0 < n && n < (2 ^ (23 :: Integer)) - 1 = Just $ LowTypeIntS n
asLowTypeMaybe ('u':cs)
  | Just n <- readMaybe cs
  , 0 < n && n < (2 ^ (23 :: Integer)) - 1 = Just $ LowTypeIntU n
asLowTypeMaybe ('f':cs)
  | Just n <- readMaybe cs
  , Just size <- asFloatSize n = Just $ LowTypeFloat size
asLowTypeMaybe _ = Nothing

asFloatSize :: Int -> Maybe FloatSize
asFloatSize 16 = Just FloatSize16
asFloatSize 32 = Just FloatSize32
asFloatSize 64 = Just FloatSize64
asFloatSize _ = Nothing

asUnaryOpMaybe :: Identifier -> Maybe (LowType, UnaryOp)
asUnaryOpMaybe name
  | [typeStr, "neg"] <- wordsBy '.' name
  , Just lowType <- asLowTypeMaybe typeStr = Just (lowType, UnaryOpNeg)
asUnaryOpMaybe name
  | [domTypeStr, convOpStr, codTypeStr] <- wordsBy '.' name
  , Just domType <- asLowTypeMaybe domTypeStr
  , Just codType <- asLowTypeMaybe codTypeStr
  , Just op <- asConvOpMaybe codType convOpStr = Just (domType, op)
asUnaryOpMaybe _ = Nothing

asConvOpMaybe :: LowType -> Identifier -> Maybe UnaryOp
asConvOpMaybe codType "trunc" = Just $ UnaryOpTrunc codType
asConvOpMaybe codType "zext" = Just $ UnaryOpZext codType
asConvOpMaybe codType "sext" = Just $ UnaryOpSext codType
asConvOpMaybe codType "ext" = Just $ UnaryOpFpExt codType
asConvOpMaybe codType "to" = Just $ UnaryOpTo codType
asConvOpMaybe _ _ = Nothing

asBinaryOpMaybe :: Identifier -> Maybe (LowType, BinaryOp)
asBinaryOpMaybe name
  | [typeStr, opStr] <- wordsBy '.' name -- e.g. name == "i8.add"
  , Just lowType <- asLowTypeMaybe typeStr
  , Just op <- asBinaryOpMaybe' opStr = Just (lowType, op)
asBinaryOpMaybe _ = Nothing

asBinaryOpMaybe' :: Identifier -> Maybe BinaryOp
asBinaryOpMaybe' "add" = Just BinaryOpAdd
asBinaryOpMaybe' "sub" = Just BinaryOpSub
asBinaryOpMaybe' "mul" = Just BinaryOpMul
asBinaryOpMaybe' "div" = Just BinaryOpDiv
asBinaryOpMaybe' "rem" = Just BinaryOpRem
asBinaryOpMaybe' "eq" = Just BinaryOpEQ
asBinaryOpMaybe' "ne" = Just BinaryOpNE
asBinaryOpMaybe' "gt" = Just BinaryOpGT
asBinaryOpMaybe' "ge" = Just BinaryOpGE
asBinaryOpMaybe' "lt" = Just BinaryOpLT
asBinaryOpMaybe' "le" = Just BinaryOpLE
asBinaryOpMaybe' "shl" = Just BinaryOpShl
asBinaryOpMaybe' "lshr" = Just BinaryOpLshr
asBinaryOpMaybe' "ashr" = Just BinaryOpAshr
asBinaryOpMaybe' "and" = Just BinaryOpAnd
asBinaryOpMaybe' "or" = Just BinaryOpOr
asBinaryOpMaybe' "xor" = Just BinaryOpXor
asBinaryOpMaybe' _ = Nothing

wordsBy :: Char -> String -> [String]
wordsBy c s =
  case dropWhile (== c) s of
    "" -> []
    s' -> do
      let (w, s'') = break (== c) s'
      w : wordsBy c s''

ushiftR :: Int -> Int -> Int
ushiftR n k = fromIntegral (fromIntegral n `shiftR` k :: Word)

ushiftR' :: (Integral a) => a -> Int -> a
ushiftR' n k = fromIntegral (fromIntegral n `shiftR` k :: Word)
