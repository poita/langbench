-- | Lexing of KBL: comment stripping, logical-line assembly and
-- tokenisation, all sharing one string-literal scanner.
module Kiln.Lexer
  ( Token (..)
  , LogicalLine (..)
  , lexSource
  , tokenizeLine
  , scanLiteral
  , scanInterpolation
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Unsafe as BU
import Data.Int (Int64)

data Token
  = TIdent !BS.ByteString
  | TInt !Int64
  | TSq !BS.ByteString
    -- ^ single-quoted literal, already unescaped
  | TDq !BS.ByteString
    -- ^ double-quoted literal: the raw bytes between the quotes
  | TSym !BS.ByteString
    -- ^ punctuation or operator
  deriving (Eq, Show)

-- | A logical line: its 1-based first physical line and its tokens.
data LogicalLine = LogicalLine
  { llNumber :: !Int
  , llTokens :: [Token]
  }
  deriving (Show)

at :: BS.ByteString -> Int -> Char
at s i = BC.index s i
{-# INLINE at #-}

-- | @scanLiteral s i@, with @s[i]@ an opening quote, returns the index just
-- past the matching closing quote, or 'Nothing' if the text ends first.
scanLiteral :: BS.ByteString -> Int -> Maybe Int
scanLiteral s i
  | at s i == '\'' = sq (i + 1)
  | otherwise = dq (i + 1)
  where
    n = BS.length s
    sq j
      | j >= n = Nothing
      | at s j == '\'' = if j + 1 < n && at s (j + 1) == '\'' then sq (j + 2) else Just (j + 1)
      | otherwise = sq (j + 1)
    dq j
      | j >= n = Nothing
      | otherwise = case at s j of
          '\\' -> if j + 1 >= n then Nothing else dq (j + 2)
          '{' ->
            if j + 1 < n && at s (j + 1) == '{'
              then dq (j + 2)
              else scanInterpolation s (j + 1) >>= dq
          '}' -> if j + 1 < n && at s (j + 1) == '}' then dq (j + 2) else dq (j + 1)
          '"' -> Just (j + 1)
          _ -> dq (j + 1)

-- | @scanInterpolation s j@, with @j@ just after an opening @{@, returns the
-- index just past the matching @}@.
scanInterpolation :: BS.ByteString -> Int -> Maybe Int
scanInterpolation s = go (1 :: Int)
  where
    n = BS.length s
    go d j
      | j >= n = Nothing
      | otherwise = case at s j of
          '"' -> scanLiteral s j >>= go d
          '\'' -> scanLiteral s j >>= go d
          '{' -> go (d + 1) (j + 1)
          '}' -> if d == 1 then Just (j + 1) else go (d - 1) (j + 1)
          _ -> go d (j + 1)

isBlank :: BS.ByteString -> Bool
isBlank = BS.all (\c -> c == 0x20 || c == 0x09)

stripTrailing :: BS.ByteString -> BS.ByteString
stripTrailing = BS.dropWhileEnd (\c -> c == 0x20 || c == 0x09)

-- | Scan one physical line: strip a comment and trailing blanks and update the
-- bracket depth.  'Nothing' on an unterminated literal or negative depth.
scanPhysical :: Int -> BS.ByteString -> Maybe (BS.ByteString, Int)
scanPhysical depth0 s = go 0 depth0
  where
    n = BS.length s
    go i d
      | i >= n = Just (stripTrailing s, d)
      | otherwise = case BU.unsafeIndex s i of
          0x22 -> scanLiteral s i >>= \j -> go j d
          0x27 -> scanLiteral s i >>= \j -> go j d
          0x23 -> Just (stripTrailing (BS.take i s), d)
          c
            | c == 0x28 || c == 0x5b -> go (i + 1) (d + 1)
            | c == 0x29 || c == 0x5d -> if d == 0 then Nothing else go (i + 1) (d - 1)
            | otherwise -> go (i + 1) d

-- | Lex a whole build file into logical lines of tokens.  @Left n@ is a
-- lexical error attributed to logical line starting at physical line @n@;
-- the earliest such line is reported.
lexSource :: BS.ByteString -> Either Int [LogicalLine]
lexSource src = go 1 1 [] 0 (BS.split 0x0a src) []
  where
    -- go lineNo groupStart accumulated depth remaining out
    go :: Int -> Int -> [BS.ByteString] -> Int -> [BS.ByteString] -> [LogicalLine] -> Either Int [LogicalLine]
    go _ start acc depth [] out
      | depth > 0 = Left start
      | otherwise = finish start acc out >>= pure . reverse
    go ln start acc depth (l : ls) out =
      let start' = if null acc then ln else start
       in case scanPhysical depth l of
            Nothing -> Left start'
            Just (text, depth')
              | depth' == 0 -> do
                  out' <- finish start' (text : acc) out
                  go (ln + 1) (ln + 1) [] 0 ls out'
              | otherwise -> go (ln + 1) start' (text : acc) depth' ls out
    finish start acc out =
      let text = BS.intercalate " " (reverse acc)
       in if isBlank text
            then Right out
            else case tokenizeLine text of
              Nothing -> Left start
              Just toks -> Right (LogicalLine start toks : out)

isIdentStart, isIdentChar, isDigit :: Char -> Bool
isIdentStart c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
isDigit c = c >= '0' && c <= '9'
isIdentChar c = isIdentStart c || isDigit c

-- | Tokenise one logical line (or an interpolation body).
tokenizeLine :: BS.ByteString -> Maybe [Token]
tokenizeLine s = go 0
  where
    n = BS.length s
    go i
      | i >= n = Just []
      | otherwise =
          let c = at s i
           in if c == ' ' || c == '\t'
                then go (i + 1)
                else
                  if isIdentStart c
                    then
                      let w = BC.takeWhile isIdentChar (BS.drop i s)
                       in (TIdent w :) <$> go (i + BS.length w)
                    else
                      if isDigit c
                        then
                          let w = BC.takeWhile isDigit (BS.drop i s)
                           in (TInt (fromInteger (BC.foldl' (\a d -> a * 10 + toInteger (fromEnum d - 48)) 0 w)) :)
                                <$> go (i + BS.length w)
                        else
                          if c == '"' || c == '\''
                            then do
                              j <- scanLiteral s i
                              let inner = BS.take (j - i - 2) (BS.drop (i + 1) s)
                              let tok = if c == '"' then TDq inner else TSq (unquoteSingle inner)
                              (tok :) <$> go j
                            else symbol i
    symbol i =
      let two = BS.take 2 (BS.drop i s)
          one = BS.take 1 (BS.drop i s)
       in if two `elem` ["|>", "||", "&&", "==", "!=", "<=", ">=", "++"]
            then (TSym two :) <$> go (i + 2)
            else
              if one `elem` ["(", ")", "[", "]", "{", "}", ",", "=", "<", ">", "~", "+", "-", "*", "/", "%", "!"]
                then (TSym one :) <$> go (i + 1)
                else Nothing

-- | Replace each @''@ with @'@.
unquoteSingle :: BS.ByteString -> BS.ByteString
unquoteSingle = BS.intercalate "'" . splitOn
  where
    splitOn b = case BS.breakSubstring "''" b of
      (pre, rest)
        | BS.null rest -> [pre]
        | otherwise -> pre : splitOn (BS.drop 2 rest)
