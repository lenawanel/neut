module Scene.Parse.Core where

import Context.App
import Context.Parse
import Context.Throw qualified as Throw
import Control.Monad
import Data.List.NonEmpty
import Data.Set qualified as S
import Data.Text qualified as T
import Data.Void
import Entity.BaseName qualified as BN
import Entity.Const
import Entity.FilePos
import Entity.Hint
import Entity.Hint.Reflect qualified as Hint
import Entity.Log qualified as L
import Path
import Text.Megaparsec
import Text.Megaparsec.Char
import Text.Megaparsec.Char.Lexer qualified as L
import Text.Read qualified as R

type Parser = ParsecT Void T.Text App

run :: Parser a -> Path Abs File -> App a
run parser path = do
  ensureExistence path
  let filePath = toFilePath path
  fileContent <- readSourceFile path
  result <- runParserT (spaceConsumer >> parser) filePath fileContent
  case result of
    Right v ->
      return v
    Left errorBundle ->
      Throw.throw $ createParseError errorBundle

createParseError :: ParseErrorBundle T.Text Void -> L.Error
createParseError errorBundle = do
  let (foo, posState) = attachSourcePos errorOffset (bundleErrors errorBundle) (bundlePosState errorBundle)
  let hint = Hint.fromSourcePos $ pstateSourcePos posState
  let message = T.pack $ concatMap (parseErrorTextPretty . fst) $ toList foo
  L.MakeError [L.logError (fromHint hint) message]

getCurrentHint :: Parser Hint
getCurrentHint =
  Hint.fromSourcePos <$> getSourcePos

spaceConsumer :: Parser ()
spaceConsumer =
  L.space
    space1
    (L.skipLineComment "//")
    (L.skipBlockCommentNested "/-" "-/")

lexeme :: Parser a -> Parser a
lexeme =
  L.lexeme spaceConsumer

symbol :: Parser T.Text
symbol = do
  lexeme $ takeWhile1P Nothing (`S.notMember` nonSymbolCharSet)

baseName :: Parser BN.BaseName
baseName = do
  bn <- takeWhile1P Nothing (`S.notMember` nonBaseNameCharSet)
  lexeme $ return $ BN.fromText bn

keyword :: T.Text -> Parser ()
keyword expected = do
  void $ chunk expected
  notFollowedBy nonSymbolChar
  spaceConsumer

delimiter :: T.Text -> Parser ()
delimiter expected = do
  lexeme $ void $ chunk expected

nonSymbolChar :: Parser Char
nonSymbolChar =
  satisfy (`S.notMember` nonSymbolCharSet) <?> "non-symbol character"

string :: Parser T.Text
string = do
  lexeme $ do
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

float :: Parser Double
float = do
  s <- symbol
  case R.readMaybe (T.unpack s) of
    Just value ->
      return value
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

betweenParen :: Parser a -> Parser a
betweenParen =
  between (delimiter "(") (delimiter ")")

betweenAngle :: Parser a -> Parser a
betweenAngle =
  between (delimiter "<") (delimiter ">")

betweenBrace :: Parser a -> Parser a
betweenBrace =
  between (delimiter "{") (delimiter "}")

betweenBracket :: Parser a -> Parser a
betweenBracket =
  between (delimiter "[") (delimiter "]")

importBlock :: Parser a -> Parser a
importBlock p = do
  keyword "import"
  betweenBrace p

useBlock :: Parser a -> Parser a
useBlock p = do
  keyword "use"
  betweenBrace p

commaList :: Parser a -> Parser [a]
commaList f = do
  sepBy f (delimiter ",")

argList :: Parser a -> Parser [a]
argList f = do
  betweenParen $ commaList f

impArgList :: Parser a -> Parser [a]
impArgList f =
  choice
    [ betweenAngle $ commaList f,
      return []
    ]

manyList :: Parser a -> Parser [a]
manyList f =
  many $ delimiter "-" >> f

var :: Parser (Hint, T.Text)
var = do
  m <- getCurrentHint
  x <- symbol
  return (m, x)

{-# INLINE nonSymbolCharSet #-}
nonSymbolCharSet :: S.Set Char
nonSymbolCharSet =
  S.fromList "=() \"\n\t:;,!?<>[]{}"

{-# INLINE nonBaseNameCharSet #-}
nonBaseNameCharSet :: S.Set Char
nonBaseNameCharSet =
  S.insert nsSepChar nonSymbolCharSet

{-# INLINE spaceCharSet #-}
spaceCharSet :: S.Set Char
spaceCharSet =
  S.fromList " \n\t"

asTokens :: T.Text -> ErrorItem Char
asTokens s =
  Tokens $ fromList $ T.unpack s

asLabel :: T.Text -> ErrorItem Char
asLabel s =
  Tokens $ fromList $ T.unpack s
