module Scene.Parse.Core where

import Context.App
import Context.Gensym qualified as Gensym
import Context.Throw qualified as Throw
import Control.Monad
import Control.Monad.Trans
import Data.List.NonEmpty
import Data.Set qualified as S
import Data.Text qualified as T
import Data.Void
import Entity.BaseName qualified as BN
import Entity.C
import Entity.Const
import Entity.Error qualified as E
import Entity.Hint
import Entity.Hint.Reflect qualified as Hint
import Path
import Text.Megaparsec
import Text.Megaparsec.Char hiding (string')
import Text.Megaparsec.Char.Lexer qualified as L
import Text.Read qualified as R

type Parser = ParsecT Void T.Text App

run :: Parser a -> Path Abs File -> T.Text -> App a
run parser path fileContent = do
  let filePath = toFilePath path
  result <- runParserT (spaceConsumer >> parser) filePath fileContent
  case result of
    Right v ->
      return v
    Left errorBundle ->
      Throw.throw $ createParseError errorBundle

run' :: Parser a -> Path Abs File -> T.Text -> App a
run' parser path fileContent = do
  let filePath = toFilePath path
  result <- runParserT parser filePath fileContent
  case result of
    Right v ->
      return v
    Left errorBundle ->
      Throw.throw $ createParseError errorBundle

createParseError :: ParseErrorBundle T.Text Void -> E.Error
createParseError errorBundle = do
  let (foo, posState) = attachSourcePos errorOffset (bundleErrors errorBundle) (bundlePosState errorBundle)
  let hint = Hint.fromSourcePos $ pstateSourcePos posState
  let message = T.pack $ concatMap (parseErrorTextPretty . fst) $ toList foo
  E.newError hint message

getCurrentHint :: Parser Hint
getCurrentHint =
  Hint.fromSourcePos <$> getSourcePos

skipSpace :: Parser ()
skipSpace =
  L.space asciiSpaceOrNewLine1 empty empty

comment :: Parser T.Text
comment = do
  skipSpace
  chunk "//"
  takeWhileP (Just "character") (/= '\n')

{-# INLINE spaceConsumer #-}
spaceConsumer :: Parser ()
spaceConsumer =
  L.space asciiSpaceOrNewLine1 (L.skipLineComment "//") empty

{-# INLINE spaceConsumer' #-}
spaceConsumer' :: Parser C
spaceConsumer' =
  hidden $ do
    skipSpace
    many (comment <* skipSpace)

{-# INLINE isAsciiSpace #-}
isAsciiSpace :: Char -> Bool
isAsciiSpace c =
  c == ' '

{-# INLINE asciiSpaceOrNewLine1 #-}
asciiSpaceOrNewLine1 :: Parser ()
asciiSpaceOrNewLine1 =
  void $ takeWhile1P (Just "space or newline") isAsciiSpaceOrNewLine

{-# INLINE asciiSpace1 #-}
asciiSpace1 :: Parser ()
asciiSpace1 =
  void $ takeWhile1P (Just "space") isAsciiSpaceOrNewLine

{-# INLINE isAsciiSpaceOrNewLine #-}
isAsciiSpaceOrNewLine :: Char -> Bool
isAsciiSpaceOrNewLine c =
  c == ' ' || c == '\n'

{-# INLINE lexeme #-}
lexeme :: Parser a -> Parser a
lexeme =
  L.lexeme spaceConsumer

{-# INLINE lexeme' #-}
lexeme' :: Parser a -> Parser (a, C)
lexeme' p = do
  v <- p
  c <- spaceConsumer' -- read spaces *before* p
  return (v, c)

symbol :: Parser T.Text
symbol = do
  lexeme $ takeWhile1P Nothing (`S.notMember` nonSymbolCharSet)

symbol' :: Parser (T.Text, C)
symbol' = do
  lexeme' $ takeWhile1P Nothing (`S.notMember` nonSymbolCharSet)

baseName :: Parser BN.BaseName
baseName = do
  lexeme $ do
    bn <- takeWhile1P Nothing (`S.notMember` nonBaseNameCharSet)
    return $ BN.fromText bn

keyword :: T.Text -> Parser ()
keyword expected = do
  lexeme $ try $ do
    _ <- chunk expected
    label (T.unpack expected) $ notFollowedBy symbol

keyword' :: T.Text -> Parser C
keyword' expected = do
  fmap snd $ lexeme' $ try $ do
    _ <- chunk expected
    label (T.unpack expected) $ notFollowedBy symbol

nonSymbolChar :: Parser Char
nonSymbolChar =
  satisfy (`S.notMember` nonSymbolCharSet) <?> "non-symbol character"

delimiter :: T.Text -> Parser ()
delimiter expected = do
  lexeme $ void $ chunk expected

delimiter' :: T.Text -> Parser C
delimiter' expected = do
  fmap snd $ lexeme' $ void $ chunk expected

string :: Parser T.Text
string =
  lexeme $ do
    _ <- char '\"'
    T.pack <$> manyTill L.charLiteral (char '\"')

string' :: Parser (T.Text, C)
string' =
  lexeme' $ do
    _ <- char '\"'
    T.pack <$> manyTill L.charLiteral (char '\"')

integer :: Parser Integer
integer = do
  s <- symbol
  case R.readMaybe (T.unpack s) of
    Just value ->
      return value
    Nothing ->
      failure (Just (asTokens s)) (S.fromList [asLabel "integer"])

integer' :: Parser (Integer, C)
integer' = do
  (s, c) <- symbol'
  case R.readMaybe (T.unpack s) of
    Just value ->
      return (value, c)
    Nothing ->
      failure (Just (asTokens s)) (S.fromList [asLabel "integer"])

float :: Parser Double
float = do
  s <- symbol
  case R.readMaybe (T.unpack s) of
    Just value ->
      return value
    Nothing -> do
      failure (Just (asTokens s)) (S.fromList [asLabel "float"])

float' :: Parser (Double, C)
float' = do
  (s, c) <- symbol'
  case R.readMaybe (T.unpack s) of
    Just value ->
      return (value, c)
    Nothing -> do
      failure (Just (asTokens s)) (S.fromList [asLabel "float"])

bool :: Parser Bool
bool = do
  s <- symbol
  case s of
    "true" ->
      return True
    "false" ->
      return False
    _ -> do
      failure (Just (asTokens s)) (S.fromList [asTokens "true", asTokens "false"])

bool' :: Parser (Bool, C)
bool' = do
  (s, c) <- symbol'
  case s of
    "true" ->
      return (True, c)
    "false" ->
      return (False, c)
    _ -> do
      failure (Just (asTokens s)) (S.fromList [asTokens "true", asTokens "false"])

betweenParen :: Parser a -> Parser a
betweenParen =
  between (delimiter "(") (delimiter ")")

betweenParen' :: Parser a -> Parser (C, (a, C))
betweenParen' p = do
  c1 <- delimiter' "("
  v <- p
  c2 <- delimiter' ")"
  return (c1, (v, c2))

betweenBrace :: Parser a -> Parser a
betweenBrace =
  between (delimiter "{") (delimiter "}")

betweenBrace' :: Parser a -> Parser (C, (a, C))
betweenBrace' p = do
  c1 <- delimiter' "{"
  v <- p
  c2 <- delimiter' "}"
  return (c1, (v, c2))

betweenBracket :: Parser a -> Parser a
betweenBracket =
  between (delimiter "[") (delimiter "]")

betweenBracket' :: Parser a -> Parser (C, (a, C))
betweenBracket' p = do
  c1 <- delimiter' "["
  v <- p
  c2 <- delimiter' "]"
  return (c1, (v, c2))

-- betweenBracket' :: Parser a -> Parser a
-- betweenBracket' =
--   between (delimiter' "[") (delimiter' "]")

betweenAngle :: Parser a -> Parser a
betweenAngle =
  between (delimiter "<") (delimiter ">")

betweenAngle' :: Parser a -> Parser (C, (a, C))
betweenAngle' p = do
  c1 <- delimiter' "<"
  v <- p
  c2 <- delimiter' ">"
  return (c1, (v, c2))

commaList :: Parser a -> Parser [a]
commaList f = do
  sepBy f (delimiter ",")

argList :: Parser a -> Parser [a]
argList f = do
  lexeme $ betweenParen $ commaList f

argList' :: Parser a -> Parser (C, ([a], C))
argList' f = do
  c1 <- delimiter' "("
  vs <- commaList f
  c2 <- delimiter' ")"
  return (c1, (vs, c2))

-- lexeme $ betweenParen $ commaList f

impArgList :: Parser a -> Parser [a]
impArgList f =
  choice
    [ betweenBracket $ commaList f,
      return []
    ]

manyList :: Parser a -> Parser [a]
manyList f =
  many $ delimiter "-" >> f

bulletListOrCommaSeq :: Parser a -> Parser [a]
bulletListOrCommaSeq f =
  choice
    [ some $ delimiter "-" >> f,
      commaList f
    ]

argSeqOrList :: Parser a -> Parser [a]
argSeqOrList p =
  choice
    [ argList p,
      keyword "of" >> betweenBrace (manyList p)
    ]

var :: Parser ((Hint, T.Text), C)
var = do
  m <- getCurrentHint
  (x, c) <- symbol'
  if x /= "_"
    then return ((m, x), c)
    else do
      unusedVar <- lift Gensym.newTextForHole
      return ((m, unusedVar), c)

{-# INLINE nonSymbolCharSet #-}
nonSymbolCharSet :: S.Set Char
nonSymbolCharSet =
  S.fromList "=() \"\n\t:;,<>[]{}/*"

{-# INLINE nonBaseNameCharSet #-}
nonBaseNameCharSet :: S.Set Char
nonBaseNameCharSet =
  S.insert nsSepChar nonSymbolCharSet

asTokens :: T.Text -> ErrorItem Char
asTokens s =
  Tokens $ fromList $ T.unpack s

asLabel :: T.Text -> ErrorItem Char
asLabel s =
  Label $ fromList $ T.unpack s
