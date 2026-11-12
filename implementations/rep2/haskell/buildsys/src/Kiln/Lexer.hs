{-# LANGUAGE LambdaCase #-}
-- | Lexical analysis of KBL: comment stripping, logical-line assembly and
-- tokenisation, plus the string-literal reader.
--
-- All three stages share one /literal scanner/ ('skipDQ', 'skipSQ',
-- 'skipRegion') so they can never disagree about where a literal ends.
module Kiln.Lexer
  ( Token (..)
  , LogicalLine (..)
  , lexFile
  , tokenize
  , RawPart (..)
  , readDoubleQuoted
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Unsafe as BU
import Data.Word (Word8)

-- | A token. Double-quoted literals keep their raw content until the parser
-- reads them with 'readDoubleQuoted'; single-quoted literals are decoded.
data Token
  = TIdent !B.ByteString
  | TInt !Int
  | TDQ !B.ByteString
  | TSQ !B.ByteString
  | TSym !B.ByteString
    -- ^ punctuation and operators
  deriving (Eq, Show)

-- | A logical line: its first physical line number and its tokens.
data LogicalLine = LogicalLine
  { llNumber :: !Int
  , llTokens :: [Token]
  }
  deriving (Eq, Show)

at :: B.ByteString -> Int -> Word8
at = BU.unsafeIndex

c :: Char -> Word8
c = fromIntegral . fromEnum

-- | Skip the rest of a double-quoted literal. The index is just past the
-- opening quote; the result is just past the closing quote.
skipDQ :: B.ByteString -> Int -> Maybe Int
skipDQ s = go
  where
    n = B.length s
    go i
      | i >= n = Nothing
      | otherwise =
          let b = at s i
              nxt = if i + 1 < n then Just (at s (i + 1)) else Nothing
           in if
                | b == c '\\' -> if i + 1 >= n then Nothing else go (i + 2)
                | b == c '"' -> Just (i + 1)
                | b == c '{' ->
                    if nxt == Just (c '{')
                      then go (i + 2)
                      else skipRegion s (i + 1) 1 >>= go
                | b == c '}' && nxt == Just (c '}') -> go (i + 2)
                | otherwise -> go (i + 1)

-- | Skip an interpolation region; the index is just past the opening @{@ and
-- the depth is 1. The result is just past the matching @}@.
skipRegion :: B.ByteString -> Int -> Int -> Maybe Int
skipRegion s = go
  where
    n = B.length s
    go i d
      | i >= n = Nothing
      | otherwise =
          let b = at s i
           in if
                | b == c '"' -> skipDQ s (i + 1) >>= \j -> go j d
                | b == c '\'' -> skipSQ s (i + 1) >>= \j -> go j d
                | b == c '{' -> go (i + 1) (d + 1)
                | b == c '}' -> if d == 1 then Just (i + 1) else go (i + 1) (d - 1)
                | otherwise -> go (i + 1) d

-- | Skip the rest of a single-quoted literal.
skipSQ :: B.ByteString -> Int -> Maybe Int
skipSQ s = go
  where
    n = B.length s
    go i
      | i >= n = Nothing
      | at s i == c '\'' =
          if i + 1 < n && at s (i + 1) == c '\'' then go (i + 2) else Just (i + 1)
      | otherwise = go (i + 1)

-- | Stages 1 and 2 for one physical line: strip the comment and update the
-- bracket depth. 'Nothing' is a lexical error.
scanPhysical :: Int -> B.ByteString -> Maybe (B.ByteString, Int)
scanPhysical depth0 s = go 0 depth0
  where
    n = B.length s
    go i d
      | i >= n = Just (s, d)
      | otherwise =
          let b = at s i
           in if
                | b == c '"' -> skipDQ s (i + 1) >>= \j -> go j d
                | b == c '\'' -> skipSQ s (i + 1) >>= \j -> go j d
                | b == c '#' -> Just (B.take i s, d)
                | b == c '(' || b == c '[' -> go (i + 1) (d + 1)
                | b == c ')' || b == c ']' ->
                    if d - 1 < 0 then Nothing else go (i + 1) (d - 1)
                | otherwise -> go (i + 1) d

stripTrailing :: B.ByteString -> B.ByteString
stripTrailing = B.dropWhileEnd (\b -> b == 32 || b == 9)

blank :: B.ByteString -> Bool
blank = B.all (\b -> b == 32 || b == 9)

-- | Lex a whole build file. 'Left' carries the line number of the earliest
-- logical line with a lexical error.
lexFile :: B.ByteString -> Either Int [LogicalLine]
lexFile src = go 1 (B.split 10 src) Nothing 0 []
  where
    -- current group: (first line number, reversed physical lines)
    go _ [] Nothing _ acc = Right (reverse acc)
    go _ [] (Just (start, _)) _ _ = Left start
    go ln (p : ps) grp depth acc =
      let start = maybe ln fst grp
          pending = maybe [] snd grp
       in case scanPhysical depth p of
            Nothing -> Left start
            Just (text, d') ->
              let text' = stripTrailing text
                  pending' = text' : pending
               in if d' == 0
                    then
                      let joined = B.intercalate " " (reverse pending')
                       in if blank joined
                            then go (ln + 1) ps Nothing 0 acc
                            else case tokenize joined of
                              Left () -> Left start
                              Right toks -> go (ln + 1) ps Nothing 0 (LogicalLine start toks : acc)
                    else go (ln + 1) ps (Just (start, pending')) d' acc

-- | Split a logical line (or an interpolation body) into tokens.
tokenize :: B.ByteString -> Either () [Token]
tokenize s = go 0
  where
    n = B.length s
    go i
      | i >= n = Right []
      | otherwise =
          let b = at s i
           in if
                | b == 32 || b == 9 -> go (i + 1)
                | isIdStart b ->
                    let tok = B.takeWhile isIdChar (B.drop i s)
                     in (TIdent tok :) <$> go (i + B.length tok)
                | isDigit b ->
                    let tok = B.takeWhile isDigit (B.drop i s)
                        v = B.foldl' (\a d -> a * 10 + fromIntegral (d - 48)) (0 :: Integer) tok
                     in (TInt (fromInteger v) :) <$> go (i + B.length tok)
                | b == c '"' -> case skipDQ s (i + 1) of
                    Nothing -> Left ()
                    Just j -> (TDQ (B.take (j - i - 2) (B.drop (i + 1) s)) :) <$> go j
                | b == c '\'' -> case skipSQ s (i + 1) of
                    Nothing -> Left ()
                    Just j -> (TSQ (unquote (B.take (j - i - 2) (B.drop (i + 1) s))) :) <$> go j
                | otherwise ->
                    let two = B.take 2 (B.drop i s)
                     in if two `elem` twoCharOps
                          then (TSym two :) <$> go (i + 2)
                          else
                            let one = B.take 1 (B.drop i s)
                             in if one `elem` oneCharSyms
                                  then (TSym one :) <$> go (i + 1)
                                  else Left ()
    twoCharOps = ["|>", "||", "&&", "==", "!=", "<=", ">=", "++"]
    oneCharSyms = map BC.singleton "()[]{},=<>~+-*/%!"
    unquote = BC.pack . dedupe . BC.unpack
    dedupe ('\'' : '\'' : r) = '\'' : dedupe r
    dedupe (x : r) = x : dedupe r
    dedupe [] = []

isIdStart, isIdChar, isDigit :: Word8 -> Bool
isIdStart b = (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95
isIdChar b = isIdStart b || isDigit b
isDigit b = b >= 48 && b <= 57

-- | A piece of a double-quoted literal, with interpolation bodies already
-- tokenised.
data RawPart = RLit !B.ByteString | RInterp [Token]
  deriving (Eq, Show)

-- | Read the raw content of a double-quoted literal (between the quotes).
-- 'Nothing' is a syntax error: bad escape, lone @}@, unterminated or empty
-- interpolation, or an interpolation body that does not tokenise.
readDoubleQuoted :: B.ByteString -> Maybe [RawPart]
readDoubleQuoted s = go 0 [] []
  where
    n = B.length s
    flush lit parts
      | null lit = parts
      | otherwise = RLit (B.pack (reverse lit)) : parts
    go i lit parts
      | i >= n = Just (reverse (flush lit parts))
      | otherwise =
          let b = at s i
              nxt = if i + 1 < n then Just (at s (i + 1)) else Nothing
           in if
                | b == c '\\' -> case nxt of
                    Just e | Just r <- lookup e escapes -> go (i + 2) (r : lit) parts
                    _ -> Nothing
                | b == c '{' ->
                    if nxt == Just (c '{')
                      then go (i + 2) (c '{' : lit) parts
                      else do
                        j <- skipRegion s (i + 1) 1
                        let body = B.take (j - i - 2) (B.drop (i + 1) s)
                        toks <- either (const Nothing) Just (tokenize body)
                        if null toks
                          then Nothing
                          else go j [] (RInterp toks : flush lit parts)
                | b == c '}' ->
                    if nxt == Just (c '}') then go (i + 2) (c '}' : lit) parts else Nothing
                | otherwise -> go (i + 1) (b : lit) parts
    escapes =
      [ (c '\\', c '\\'), (c '"', c '"'), (c 'n', 10), (c 't', 9)
      , (c 'r', 13), (c '0', 0) ]
