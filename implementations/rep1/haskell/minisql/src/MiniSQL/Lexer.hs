-- | Tokenizer. Lexing never fails: anything that is not a valid token is
-- turned into a 'TInvalid' or 'TUnterminated' token, which makes the
-- statement containing it a syntax error while leaving the surrounding
-- statements untouched.
module MiniSQL.Lexer
  ( Token (..)
  , Keyword (..)
  , tokenize
  , splitStatements
  ) where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit, toLower)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T

-- | Reserved words. They can never be used as names.
data Keyword
  = KSelect | KFrom | KWhere | KAnd | KOr | KNot | KNull | KIs | KLike | KAs
  | KInsert | KInto | KValues | KDelete | KUpdate | KSet | KCreate | KTable
  | KInteger | KText | KInner | KJoin | KOn | KGroup | KBy | KHaving | KOrder
  | KAsc | KDesc | KLimit | KOffset | KLeft | KRight | KFull | KOuter
  | KCross | KNatural
  deriving (Eq, Show, Enum, Bounded)

-- | A lexical token.
data Token
  = TKeyword !Keyword
  | TIdent !Text
  -- ^ A non-reserved identifier, lower-cased.
  | TInt !Integer
  | TString !Text
  | TPlus | TMinus | TStar | TSlash | TPercent
  | TEq | TNe | TLt | TLe | TGt | TGe
  | TLParen | TRParen | TComma | TDot | TSemi
  | TInvalid !Char
  -- ^ A character that starts no token.
  | TUnterminated
  -- ^ A string literal that is never closed.
  deriving (Eq, Show)

keywordTable :: Map Text Keyword
keywordTable =
  Map.fromList [(T.pack (map toLower (drop 1 (show k))), k) | k <- [minBound .. maxBound]]

isIdentStart, isIdentChar :: Char -> Bool
isIdentStart c = isAsciiLower c || isAsciiUpper c || c == '_'
isIdentChar c = isIdentStart c || isAsciiDigitC c

isAsciiDigitC :: Char -> Bool
isAsciiDigitC c = isDigit c && c < '\x80'

isSpaceC :: Char -> Bool
isSpaceC c = c `elem` " \t\r\n\f\v"

-- | Split source text into tokens, dropping whitespace and @--@ comments.
tokenize :: Text -> [Token]
tokenize input = case T.uncons input of
  Nothing -> []
  Just (c, rest)
    | isSpaceC c -> tokenize (T.dropWhile isSpaceC rest)
    | isIdentStart c ->
        let (name, rest') = T.span isIdentChar input
            lower = T.toLower name
         in maybe (TIdent lower) TKeyword (Map.lookup lower keywordTable) : tokenize rest'
    | isAsciiDigitC c ->
        let (digits, rest') = T.span isAsciiDigitC input
         in TInt (T.foldl' (\n d -> n * 10 + toInteger (fromEnum d - 48)) 0 digits) : tokenize rest'
    | c == '\'' -> string rest []
    | c == '-', Just ('-', r) <- T.uncons rest -> tokenize (T.dropWhile (/= '\n') r)
    | c == '<', Just ('=', r) <- T.uncons rest -> TLe : tokenize r
    | c == '<', Just ('>', r) <- T.uncons rest -> TNe : tokenize r
    | c == '>', Just ('=', r) <- T.uncons rest -> TGe : tokenize r
    | c == '=', Just ('=', r) <- T.uncons rest -> TEq : tokenize r
    | c == '!', Just ('=', r) <- T.uncons rest -> TNe : tokenize r
    | otherwise -> single c : tokenize rest
  where
    single c = case c of
      '+' -> TPlus
      '-' -> TMinus
      '*' -> TStar
      '/' -> TSlash
      '%' -> TPercent
      '=' -> TEq
      '<' -> TLt
      '>' -> TGt
      '(' -> TLParen
      ')' -> TRParen
      ',' -> TComma
      '.' -> TDot
      ';' -> TSemi
      _ -> TInvalid c

    -- Scan the body of a string literal; @acc@ holds finished chunks
    -- (reversed). A doubled quote contributes one literal quote.
    string t acc =
      let (chunk, r) = T.break (== '\'') t
       in case T.uncons r of
            Nothing -> [TUnterminated]
            Just (_, r')
              | Just ('\'', r'') <- T.uncons r' -> string r'' (T.pack "'" : chunk : acc)
              | otherwise -> TString (T.concat (reverse (chunk : acc))) : tokenize r'

-- | Split a token stream into statements at every 'TSemi'. Empty statements
-- are dropped; a final statement without a terminating @;@ is kept.
splitStatements :: [Token] -> [[Token]]
splitStatements [] = []
splitStatements ts =
  let (stmt, rest) = break (== TSemi) ts
      more = splitStatements (drop 1 rest)
   in if null stmt then more else stmt : more
