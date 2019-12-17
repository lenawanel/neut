module Emit
  ( emit
  ) where

import Control.Monad.State

import Data.Basic
import Data.Env
import Data.LLVM

emit :: LLVM -> WithEnv [String]
emit mainTerm = do
  lenv <- gets llvmEnv
  g <- emitGlobal
  zs <- emitDefinition "main" [] mainTerm
  xs <- forM lenv $ \(name, (args, body)) -> emitDefinition name args body
  return $ g ++ zs ++ concat xs

emitDefinition :: Identifier -> [Identifier] -> LLVM -> WithEnv [String]
emitDefinition name args asm = do
  let prologue = sig name args ++ " {"
  content <- emitLLVM name asm
  let epilogue = "}"
  return $ [prologue] ++ content ++ [epilogue]

sig :: Identifier -> [Identifier] -> String
sig "main" args = "define i64 @main" ++ showArgs (map LLVMDataLocal args)
sig name args =
  "define i8* " ++
  showLLVMData (LLVMDataGlobal name) ++ showArgs (map LLVMDataLocal args)

emitBlock :: Identifier -> Identifier -> LLVM -> WithEnv [String]
emitBlock funName name asm = do
  a <- emitLLVM funName asm
  return $ emitLabel name : a

-- FIXME: callはcall fastccにするべきっぽい？
emitLLVM :: Identifier -> LLVM -> WithEnv [String]
emitLLVM funName (LLVMCall f args) = do
  tmp <- newNameWith "tmp"
  op <-
    emitOp $
    unwords
      [ showLLVMData (LLVMDataLocal tmp)
      , "="
      , "tail call i8*"
      , showLLVMData f ++ showArgs args
      ]
  a <- emitRet funName (LLVMDataLocal tmp)
  return $ op ++ a
emitLLVM funName (LLVMSwitch (d, lowType) defaultBranch branchList) = do
  defaultLabel <- newNameWith "default"
  labelList <- constructLabelList branchList
  op <-
    emitOp $
    unwords
      [ "switch"
      , showLowTypeEmit lowType
      , showLLVMData d ++ ","
      , "label"
      , showLLVMData (LLVMDataLocal defaultLabel)
      , showBranchList lowType $ zip (map fst branchList) labelList
      ]
  let asmList = map snd branchList
  xs <-
    forM (zip labelList asmList ++ [(defaultLabel, defaultBranch)]) $
    uncurry (emitBlock funName)
  return $ op ++ concat xs
emitLLVM funName (LLVMReturn d) = emitRet funName d
emitLLVM funName (LLVMLet x (LLVMCall f args) cont) = do
  op <-
    emitOp $
    unwords
      [ showLLVMData (LLVMDataLocal x)
      , "="
      , "call i8*"
      , showLLVMData f ++ showArgs args
      ]
  a <- emitLLVM funName cont
  return $ op ++ a
emitLLVM funName (LLVMLet x (LLVMSwitch d defaultBranch branchList) cont) = do
  let (labelList, ls) = unzip branchList
  let ls' = map (\l -> LLVMLet x l cont) ls
  let defaultBranch' = LLVMLet x defaultBranch cont
  emitLLVM funName (LLVMSwitch d defaultBranch' (zip labelList ls'))
emitLLVM funName (LLVMLet x (LLVMReturn d) cont)
  -- by the definition of LLVM.hs, the type of `d` is always `i8*`.
 = emitLLVM funName (LLVMLet x (LLVMBitcast d voidPtr voidPtr) cont)
emitLLVM funName (LLVMLet x (LLVMLet y cont1 cont2) cont3) =
  emitLLVM funName (LLVMLet y cont1 (LLVMLet x cont2 cont3))
emitLLVM funName (LLVMLet x (LLVMGetElementPtr base (i, n)) cont) = do
  op <-
    emitOp $
    unwords
      [ showLLVMData (LLVMDataLocal x)
      , "= getelementptr"
      , showStruct n ++ ","
      , showStruct n ++ "*"
      , showLLVMData base ++ ","
      , showIndex [0, i]
      ]
  xs <- emitLLVM funName cont
  return $ op ++ xs
emitLLVM funName (LLVMLet x (LLVMBitcast d fromType toType) cont) = do
  emitCast funName x "bitcast" d fromType toType cont
emitLLVM funName (LLVMLet x (LLVMIntToPointer d fromType toType) cont) = do
  emitCast funName x "inttoptr" d fromType toType cont
emitLLVM funName (LLVMLet x (LLVMPointerToInt d fromType toType) cont) = do
  emitCast funName x "ptrtoint" d fromType toType cont
emitLLVM funName (LLVMLet x (LLVMLoad d) cont) = do
  op <-
    emitOp $
    unwords
      [showLLVMData (LLVMDataLocal x), "=", "load i8*, i8**", showLLVMData d]
  a <- emitLLVM funName cont
  return $ op ++ a
emitLLVM funName (LLVMLet _ (LLVMStore (d1, t1) (d2, t2)) cont) = do
  op <-
    emitOp $
    unwords
      [ "store"
      , showLowTypeEmit t1
      , showLLVMData d1 ++ ","
      , showLowTypeEmit t2
      , showLLVMData d2
      ]
  a <- emitLLVM funName cont
  return $ op ++ a
emitLLVM funName (LLVMLet x (LLVMAlloc len) cont) = do
  size <- newNameWith "sizeptr"
  -- Use getelementptr to realize `sizeof`. More info:
  --   http://nondot.org/sabre/LLVMNotes/SizeOf-OffsetOf-VariableSizedStructs.txt
  op1 <-
    emitOp $
    unwords
      [ showLLVMData (LLVMDataLocal size)
      , "="
      , "getelementptr i64, i64* null, i32 " ++ show len
      ]
  casted <- newNameWith "size"
  op2 <-
    emitOp $
    unwords
      [ showLLVMData (LLVMDataLocal casted)
      , "="
      , "ptrtoint i64*"
      , showLLVMData (LLVMDataLocal size)
      , "to i64"
      ]
  op3 <-
    emitOp $
    unwords
      [ showLLVMData (LLVMDataLocal x)
      , "="
      , "call"
      , "i8*"
      , "@malloc(i64 " ++ showLLVMData (LLVMDataLocal casted) ++ ")"
      ]
  a <- emitLLVM funName cont
  return $ op1 ++ op2 ++ op3 ++ a
emitLLVM funName (LLVMLet _ (LLVMFree d) cont) = do
  op <- emitOp $ unwords ["call", "void", "@free(i8* " ++ showLLVMData d ++ ")"]
  a <- emitLLVM funName cont
  return $ op ++ a
emitLLVM funName (LLVMLet x (LLVMUnaryOp (UnaryOpNeg, t@(LowTypeFloat _)) d) cont) = do
  emitUnaryOp funName x t "fneg" d cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpAdd, t@(LowTypeSignedInt _)) d1 d2) cont) = do
  emitBinaryOp funName x t "add" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpAdd, t@(LowTypeUnsignedInt _)) d1 d2) cont) =
  emitBinaryOp funName x t "add" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpAdd, t@(LowTypeFloat _)) d1 d2) cont) = do
  emitBinaryOp funName x t "fadd" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpSub, t@(LowTypeSignedInt _)) d1 d2) cont) = do
  emitBinaryOp funName x t "sub" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpSub, t@(LowTypeUnsignedInt _)) d1 d2) cont) =
  emitBinaryOp funName x t "sub" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpSub, t@(LowTypeFloat _)) d1 d2) cont) = do
  emitBinaryOp funName x t "fsub" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpMul, t@(LowTypeSignedInt _)) d1 d2) cont) = do
  emitBinaryOp funName x t "mul" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpMul, t@(LowTypeUnsignedInt _)) d1 d2) cont) =
  emitBinaryOp funName x t "mul" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpMul, t@(LowTypeFloat _)) d1 d2) cont) = do
  emitBinaryOp funName x t "fmul" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpDiv, t@(LowTypeSignedInt _)) d1 d2) cont) = do
  emitBinaryOp funName x t "sdiv" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpDiv, t@(LowTypeUnsignedInt _)) d1 d2) cont) = do
  emitBinaryOp funName x t "udiv" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpDiv, t@(LowTypeFloat _)) d1 d2) cont) = do
  emitBinaryOp funName x t "fdiv" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpRem, t@(LowTypeSignedInt _)) d1 d2) cont) = do
  emitBinaryOp funName x t "srem" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpRem, t@(LowTypeUnsignedInt _)) d1 d2) cont) = do
  emitBinaryOp funName x t "urem" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpRem, t@(LowTypeFloat _)) d1 d2) cont) = do
  emitBinaryOp funName x t "frem" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpEQ, t@(LowTypeSignedInt _)) d1 d2) cont) =
  emitBinaryOp funName x t "icmp eq" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpEQ, t@(LowTypeUnsignedInt _)) d1 d2) cont) =
  emitBinaryOp funName x t "icmp eq" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpEQ, t@(LowTypeFloat _)) d1 d2) cont) =
  emitBinaryOp funName x t "fcmp oeq" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpNE, t@(LowTypeSignedInt _)) d1 d2) cont) =
  emitBinaryOp funName x t "icmp ne" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpNE, t@(LowTypeUnsignedInt _)) d1 d2) cont) =
  emitBinaryOp funName x t "icmp ne" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpNE, t@(LowTypeFloat _)) d1 d2) cont) =
  emitBinaryOp funName x t "fcmp one" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpGT, t@(LowTypeSignedInt _)) d1 d2) cont) =
  emitBinaryOp funName x t "icmp sgt" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpGT, t@(LowTypeUnsignedInt _)) d1 d2) cont) =
  emitBinaryOp funName x t "icmp ugt" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpGT, t@(LowTypeFloat _)) d1 d2) cont) =
  emitBinaryOp funName x t "fcmp ogt" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpGE, t@(LowTypeSignedInt _)) d1 d2) cont) =
  emitBinaryOp funName x t "icmp sge" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpGE, t@(LowTypeUnsignedInt _)) d1 d2) cont) =
  emitBinaryOp funName x t "icmp uge" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpGE, t@(LowTypeFloat _)) d1 d2) cont) =
  emitBinaryOp funName x t "fcmp oge" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpLT, t@(LowTypeSignedInt _)) d1 d2) cont) =
  emitBinaryOp funName x t "icmp slt" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpLT, t@(LowTypeUnsignedInt _)) d1 d2) cont) =
  emitBinaryOp funName x t "icmp ult" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpLT, t@(LowTypeFloat _)) d1 d2) cont) =
  emitBinaryOp funName x t "fcmp olt" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpLE, t@(LowTypeSignedInt _)) d1 d2) cont) =
  emitBinaryOp funName x t "icmp sle" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpLE, t@(LowTypeUnsignedInt _)) d1 d2) cont) =
  emitBinaryOp funName x t "icmp ule" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpLE, t@(LowTypeFloat _)) d1 d2) cont) =
  emitBinaryOp funName x t "fcmp ole" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpShl, t@(LowTypeSignedInt _)) d1 d2) cont) = do
  emitBinaryOp funName x t "shl" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpShl, t@(LowTypeUnsignedInt _)) d1 d2) cont) =
  emitBinaryOp funName x t "shl" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpLshr, t@(LowTypeSignedInt _)) d1 d2) cont) = do
  emitBinaryOp funName x t "lshr" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpLshr, t@(LowTypeUnsignedInt _)) d1 d2) cont) =
  emitBinaryOp funName x t "lshr" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpAshr, t@(LowTypeSignedInt _)) d1 d2) cont) = do
  emitBinaryOp funName x t "ashr" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpAshr, t@(LowTypeUnsignedInt _)) d1 d2) cont) =
  emitBinaryOp funName x t "ashr" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpAnd, t@(LowTypeSignedInt _)) d1 d2) cont) = do
  emitBinaryOp funName x t "and" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpAnd, t@(LowTypeUnsignedInt _)) d1 d2) cont) =
  emitBinaryOp funName x t "and" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpOr, t@(LowTypeSignedInt _)) d1 d2) cont) = do
  emitBinaryOp funName x t "or" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpOr, t@(LowTypeUnsignedInt _)) d1 d2) cont) =
  emitBinaryOp funName x t "or" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpXor, t@(LowTypeSignedInt _)) d1 d2) cont) = do
  emitBinaryOp funName x t "xor" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMBinaryOp (BinaryOpXor, t@(LowTypeUnsignedInt _)) d1 d2) cont) =
  emitBinaryOp funName x t "xor" d1 d2 cont
emitLLVM funName (LLVMLet x (LLVMPrint t d) cont) = do
  fmt <- newNameWith "fmt"
  op1 <-
    emitOp $
    unwords
      [ showLLVMData (LLVMDataLocal fmt)
      , "="
      , "getelementptr [3 x i8], [3 x i8]* @fmt.i32, i32 0, i32 0"
      ]
  tmp <- newNameWith "tmp"
  op2 <-
    emitOp $
    unwords
      [ showLLVMData (LLVMDataLocal tmp)
      , "="
      , "call"
      , "i32 (i8*, ...)"
      , "@printf(i8* " ++ showLLVMData (LLVMDataLocal fmt) ++ ","
      , showLowTypeEmit t
      , showLLVMData d ++ ")"
      ]
  a <-
    emitLLVM funName $
    LLVMLet
      x
      (LLVMIntToPointer (LLVMDataLocal tmp) (LowTypeSignedInt 32) voidPtr)
      cont
  return $ op1 ++ op2 ++ a
emitLLVM _ LLVMUnreachable = emitOp $ unwords ["unreachable"]
emitLLVM funName c = do
  tmp <- newNameWith "result"
  emitLLVM funName $ LLVMLet tmp c $ LLVMReturn (LLVMDataLocal tmp)

emitUnaryOp ::
     Identifier
  -> Identifier
  -> LowType
  -> String
  -> LLVMData
  -> LLVM
  -> WithEnv [String]
emitUnaryOp funName x t inst d cont = do
  op <-
    emitOp $
    unwords
      [ showLLVMData (LLVMDataLocal x)
      , "="
      , inst
      , showLowTypeEmit t
      , showLLVMData d
      ]
  a <- emitLLVM funName cont
  return $ op ++ a

emitBinaryOp ::
     Identifier
  -> Identifier
  -> LowType
  -> String
  -> LLVMData
  -> LLVMData
  -> LLVM
  -> WithEnv [String]
emitBinaryOp funName x t inst d1 d2 cont = do
  op <-
    emitOp $
    unwords
      [ showLLVMData (LLVMDataLocal x)
      , "="
      , inst
      , showLowTypeEmit t
      , showLLVMData d1 ++ ","
      , showLLVMData d2
      ]
  a <- emitLLVM funName cont
  return $ op ++ a

emitCast ::
     Identifier
  -> Identifier
  -> String
  -> LLVMData
  -> LowType
  -> LowType
  -> LLVM
  -> WithEnv [String]
emitCast funName x cast d fromType toType cont = do
  op <-
    emitOp $
    unwords
      [ showLLVMData (LLVMDataLocal x)
      , "="
      , cast
      , showLowTypeEmit fromType
      , showLLVMData d
      , "to"
      , showLowTypeEmit toType
      ]
  a <- emitLLVM funName cont
  return $ op ++ a

emitOp :: String -> WithEnv [String]
emitOp s = return ["  " ++ s]

emitRet :: Identifier -> LLVMData -> WithEnv [String]
emitRet "main" d = do
  tmp <- newNameWith "cast"
  op1 <-
    emitOp $
    unwords
      [ showLLVMData (LLVMDataLocal tmp)
      , "="
      , "ptrtoint"
      , "i8*"
      , showLLVMData d
      , "to"
      , "i64"
      ]
  op2 <- emitOp $ unwords ["ret i64", showLLVMData (LLVMDataLocal tmp)]
  return $ op1 ++ op2
emitRet _ d = emitOp $ unwords ["ret i8*", showLLVMData d]

emitLabel :: String -> String
emitLabel s = s ++ ":"

constructLabelList :: [(Int, LLVM)] -> WithEnv [String]
constructLabelList [] = return []
constructLabelList ((_, _):rest) = do
  label <- newNameWith "case"
  labelList <- constructLabelList rest
  return $ label : labelList

showBranchList :: LowType -> [(Int, String)] -> String
showBranchList lowType xs =
  "[" ++ showItems (uncurry (showBranch lowType)) xs ++ "]"

showBranch :: LowType -> Int -> String -> String
showBranch lowType i label =
  showLowTypeEmit lowType ++
  " " ++ show i ++ ", label " ++ showLLVMData (LLVMDataLocal label)

showIndex :: [Int] -> String
showIndex [] = ""
showIndex [i] = "i32 " ++ show i
showIndex (i:is) = "i32 " ++ show i ++ ", " ++ showIndex is

showArg :: LLVMData -> String
showArg d = "i8* " ++ showLLVMData d

showArgs :: [LLVMData] -> String
showArgs ds = "(" ++ showItems showArg ds ++ ")"

showLowTypeEmit :: LowType -> String
showLowTypeEmit (LowTypeSignedInt i) = "i" ++ show i
-- LLVM doesn't distinguish unsigned integers from signed ones
showLowTypeEmit (LowTypeUnsignedInt i) = "i" ++ show i
showLowTypeEmit (LowTypeFloat 16) = "half"
showLowTypeEmit (LowTypeFloat 32) = "float"
showLowTypeEmit (LowTypeFloat 64) = "double"
showLowTypeEmit (LowTypeFloat i) = "f" ++ show i -- shouldn't occur
showLowTypeEmit (LowTypePointer t) = showLowTypeEmit t ++ "*"
showLowTypeEmit (LowTypeStruct ts) = "{" ++ showItems showLowTypeEmit ts ++ "}"
showLowTypeEmit (LowTypeFunction ts t) =
  showLowTypeEmit t ++ " (" ++ showItems showLowTypeEmit ts ++ ")"

showStruct :: Int -> String
showStruct i = "{" ++ showItems (const "i8*") [1 .. i] ++ "}"

-- for now
emitGlobal :: WithEnv [String]
emitGlobal =
  return
    [ "@fmt.i32 = constant [3 x i8] c\"%d\00\""
    , "declare i32 @printf(i8* noalias nocapture, ...)"
    , "declare i8* @malloc(i64)"
    , "declare void @free(i8*)"
    ]

showLLVMData :: LLVMData -> String
showLLVMData (LLVMDataLocal x) = "%" ++ x
showLLVMData (LLVMDataGlobal x) = "@" ++ x
showLLVMData (LLVMDataInt i _) = show i
showLLVMData (LLVMDataFloat x _) = show x
showLLVMData (LLVMDataStruct xs) = "{" ++ showItems showLLVMData xs ++ "}"
