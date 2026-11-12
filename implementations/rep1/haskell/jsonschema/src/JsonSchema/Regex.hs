{-# LANGUAGE BangPatterns #-}
-- |
-- Module      : JsonSchema.Regex
-- Description : A small ECMA-262 regular-expression engine (membership only).
--
-- Supports the subset JSON Schema @pattern@ keywords use: alternation,
-- grouping, greedy and lazy quantifiers (@* + ? {n} {n,} {n,m}@), @.@, @^@,
-- @$@, @\\b@, @\\B@, character classes and the usual escapes.  Matching is over
-- Unicode code points and answers only "does the pattern match somewhere in
-- the string?".
--
-- The pattern is compiled to a Thompson NFA program (counted repetition is
-- expanded) and searched with a lock-step simulation that adds the start state
-- at every position, so a search costs O(P·L) set operations and can never
-- backtrack exponentially.
module JsonSchema.Regex
  ( Regex
  , compileRegex
  , regexSearch
  , matches
  ) where

import Data.Array (Array, listArray, (!))
import qualified Data.Array.Unboxed as U
import Data.Char (digitToInt, isDigit, isHexDigit, ord)
import qualified Data.IntSet as IS
import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as T

-- ---------------------------------------------------------------------------
-- Character sets

-- | Sorted, non-overlapping, non-adjacent inclusive code point ranges.
type Ranges = [(Int, Int)]

maxCp :: Int
maxCp = 0x10FFFF

normalise :: Ranges -> Ranges
normalise = merge . sortOn fst
  where
    merge ((a, b) : (c, d) : r)
      | c <= b + 1 = merge ((a, max b d) : r)
      | otherwise = (a, b) : merge ((c, d) : r)
    merge r = r

complementR :: Ranges -> Ranges
complementR rs = go 0 (normalise rs)
  where
    go !lo [] = [(lo, maxCp) | lo <= maxCp]
    go !lo ((a, b) : r) = [(lo, a - 1) | a > lo] ++ go (b + 1) r

inRanges :: Ranges -> Int -> Bool
inRanges [] _ = False
inRanges ((a, b) : r) c
  | c < a = False
  | c <= b = True
  | otherwise = inRanges r c

digitR, wordR, spaceR, lineTermR :: Ranges
digitR = [(48, 57)]
wordR = [(48, 57), (65, 90), (95, 95), (97, 122)]
spaceR =
  normalise
    [ (9, 13), (32, 32), (0xA0, 0xA0), (0x1680, 0x1680), (0x2000, 0x200A)
    , (0x2028, 0x2029), (0x202F, 0x202F), (0x205F, 0x205F), (0x3000, 0x3000), (0xFEFF, 0xFEFF)
    ]
lineTermR = [(10, 10), (13, 13), (0x2028, 0x2029)]

-- ---------------------------------------------------------------------------
-- Syntax tree and parser

data Assertion = AStart | AEnd | AWordB | ANotWordB
  deriving (Eq, Show)

data Ast
  = Empty
  | Set Ranges
  | Assert Assertion
  | Cat [Ast]
  | Alt [Ast]
  | Rep Ast Int (Maybe Int)
  | Star Ast
  | Opt Ast
  deriving (Show)

type Parser a = String -> Either String (a, String)

parseRegex :: String -> Either String Ast
parseRegex s = do
  (a, rest) <- pAlt s
  case rest of
    [] -> Right a
    (c : _) -> Left ("unexpected " ++ show c)

pAlt :: Parser Ast
pAlt s = do
  (first, rest) <- pSeq s
  go [first] rest
  where
    go acc ('|' : r) = do
      (x, r') <- pSeq r
      go (x : acc) r'
    go [x] r = Right (x, r)
    go acc r = Right (Alt (reverse acc), r)

pSeq :: Parser Ast
pSeq = go []
  where
    go acc s = case s of
      [] -> done acc s
      ('|' : _) -> done acc s
      (')' : _) -> done acc s
      _ -> do
        (atom, r) <- pAtom s
        (t, r') <- pQuant atom r
        go (t : acc) r'
    done [x] s = Right (x, s)
    done acc s = Right (Cat (reverse acc), s)

pQuant :: Ast -> Parser Ast
pQuant atom s = case s of
  ('*' : r) -> lazy 0 Nothing r
  ('+' : r) -> lazy 1 Nothing r
  ('?' : r) -> lazy 0 (Just 1) r
  ('{' : r) | Just (lo, hi, r') <- braces r -> lazy lo hi r'
  _ -> Right (atom, s)
  where
    lazy lo hi r = Right (Rep atom lo hi, case r of ('?' : r') -> r'; _ -> r)
    braces r =
      let (d1, r1) = span isDigit r
       in if null d1
            then Nothing
            else case r1 of
              ('}' : r2) -> Just (toI d1, Just (toI d1), r2)
              (',' : '}' : r2) -> Just (toI d1, Nothing, r2)
              (',' : r2) ->
                let (d2, r3) = span isDigit r2
                 in case r3 of
                      ('}' : r4) | not (null d2) -> Just (toI d1, Just (toI d2), r4)
                      _ -> Nothing
              _ -> Nothing
    toI = foldl (\a c -> min 100000 (a * 10 + digitToInt c)) 0

pAtom :: Parser Ast
pAtom s = case s of
  ('(' : '?' : ':' : r) -> group r
  ('(' : r) -> group r
  ('[' : r) -> pClass r
  ('.' : r) -> Right (Set (complementR lineTermR), r)
  ('^' : r) -> Right (Assert AStart, r)
  ('$' : r) -> Right (Assert AEnd, r)
  ('\\' : r) -> pEscape r
  (c : _) | c `elem` "*+?" -> Left ("nothing to repeat: " ++ [c])
  (c : r) -> Right (lit (ord c), r)
  [] -> Left "unexpected end of pattern"
  where
    group r = do
      (a, r') <- pAlt r
      case r' of
        (')' : r'') -> Right (a, r'')
        _ -> Left "unterminated group"

lit :: Int -> Ast
lit c = Set [(c, c)]

-- | Escape outside a class (after the backslash).
pEscape :: Parser Ast
pEscape s = case s of
  ('b' : r) -> Right (Assert AWordB, r)
  ('B' : r) -> Right (Assert ANotWordB, r)
  _ -> do
    (e, r) <- classEscape False s
    Right (either lit Set e, r)

-- | An escape in either context.  Left = a single code point, Right = a set.
classEscape :: Bool -> Parser (Either Int Ranges)
classEscape inClass s = case s of
  [] -> Left "trailing backslash"
  (c : r) -> case c of
    'd' -> set digitR r
    'D' -> set (complementR digitR) r
    'w' -> set wordR r
    'W' -> set (complementR wordR) r
    's' -> set spaceR r
    'S' -> set (complementR spaceR) r
    'n' -> ch 10 r
    'r' -> ch 13 r
    't' -> ch 9 r
    'f' -> ch 12 r
    'v' -> ch 11 r
    'b' | inClass -> ch 8 r
    '0' -> ch 0 r
    'c' -> case r of
      (l : r') | l `elem` ['a' .. 'z'] ++ ['A' .. 'Z'] -> ch (ord l `mod` 32) r'
      _ -> ch (ord '\\') s
    'x' -> case r of
      (a : b : r') | isHexDigit a && isHexDigit b -> ch (digitToInt a * 16 + digitToInt b) r'
      _ -> ch (ord 'x') r
    'u' -> case hex4 r of
      Just (hi, r')
        | hi >= 0xD800 && hi < 0xDC00
        , ('\\' : 'u' : r2) <- r'
        , Just (lo, r3) <- hex4 r2
        , lo >= 0xDC00 && lo < 0xE000 ->
            ch (0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00)) r3
        | otherwise -> ch hi r'
      Nothing -> ch (ord 'u') r
    _ -> ch (ord c) r
  where
    set x r = Right (Right x, r)
    ch x r = Right (Left x, r)
    hex4 r = case splitAt 4 r of
      (h, r') | length h == 4 && all isHexDigit h -> Just (foldl (\a d -> a * 16 + digitToInt d) 0 h, r')
      _ -> Nothing

-- | A character class; the opening bracket has been consumed.
pClass :: Parser Ast
pClass s0 =
  let (neg, s1) = case s0 of ('^' : r) -> (True, r); _ -> (False, s0)
   in go neg [] s1
  where
    go neg acc s = case s of
      [] -> Left "unterminated character class"
      (']' : r) ->
        let rs = normalise acc in Right (Set (if neg then complementR rs else rs), r)
      _ -> do
        (a, r1) <- item s
        case (a, r1) of
          (Left lo, '-' : r2@(c : _))
            | c /= ']' -> do
                (b, r3) <- item r2
                case b of
                  Left hi
                    | hi >= lo -> go neg ((lo, hi) : acc) r3
                    | otherwise -> Left "range out of order in character class"
                  Right rs -> go neg (rs ++ [(lo, lo), (45, 45)] ++ acc) r3
          _ -> go neg (either (\c -> [(c, c)]) id a ++ acc) r1
    item s = case s of
      ('\\' : r) -> classEscape True r
      (c : r) -> Right (Left (ord c), r)
      [] -> Left "unterminated character class"

-- ---------------------------------------------------------------------------
-- Compilation to an NFA program

-- Jump targets are offsets relative to the instruction itself.
data Instr
  = ISet !Ranges
  | ISplit !Int !Int
  | IJmp !Int
  | IAssert !Assertion
  | IMatch

-- | A compiled regular expression.
newtype Regex = Regex (Array Int Instr)

instance Show Regex where
  show (Regex prog) = "<regex " ++ show (length prog) ++ " instructions>"

-- | Compile a pattern; the error message says what was wrong.
compileRegex :: Text -> Either String Regex
compileRegex src = do
  ast <- parseRegex (T.unpack src)
  let prog = emit ast ++ [IMatch]
  Right (Regex (listArray (0, length prog - 1) prog))

emit :: Ast -> [Instr]
emit ast = case ast of
  Empty -> []
  Set r -> [ISet r]
  Assert a -> [IAssert a]
  Cat xs -> concatMap emit xs
  Alt [] -> []
  Alt [x] -> emit x
  Alt (x : xs) ->
    let cx = emit x
        crest = emit (Alt xs)
     in [ISplit 1 (length cx + 2)] ++ cx ++ [IJmp (length crest + 1)] ++ crest
  Star x ->
    let cx = emit x
     in [ISplit 1 (length cx + 2)] ++ cx ++ [IJmp (negate (length cx + 1))]
  Opt x ->
    let cx = emit x
     in [ISplit 1 (length cx + 1)] ++ cx
  Rep x lo hi -> emit (Cat (replicate lo x ++ rest))
    where
      rest = case hi of
        Nothing -> [Star x]
        Just h -> opts (h - lo)
      opts n
        | n <= 0 = []
        | otherwise = [Opt (Cat (x : opts (n - 1)))]

-- ---------------------------------------------------------------------------
-- Search

-- | Does the regex match anywhere in the text?  (Unanchored search.)
matches :: Regex -> Text -> Bool
matches re t = regexSearch re t

-- | Unanchored search over code points.
regexSearch :: Regex -> Text -> Bool
regexSearch (Regex prog) text = loop 0 IS.empty
  where
    n = T.length text
    subject :: U.UArray Int Char
    subject = U.listArray (0, max 0 n - 1) (T.unpack text)
    at i = ord (subject U.! i)
    isWordAt i = i >= 0 && i < n && inRanges wordR (at i)
    holds i a = case a of
      AStart -> i == 0
      AEnd -> i == n
      AWordB -> isWordAt (i - 1) /= isWordAt i
      ANotWordB -> isWordAt (i - 1) == isWordAt i
    -- Epsilon closure of the seed states at position i: returns whether the
    -- match state was reached and the consuming states.
    closure i seeds = walk (IS.toList (IS.insert 0 seeds)) IS.empty False []
      where
        walk [] _ !m acc = (m, acc)
        walk (pc : rest) seen !m acc
          | IS.member pc seen = walk rest seen m acc
          | otherwise =
              let seen' = IS.insert pc seen
               in case prog ! pc of
                    IMatch -> walk rest seen' True acc
                    ISet _ -> walk rest seen' m (pc : acc)
                    IJmp o -> walk (pc + o : rest) seen' m acc
                    ISplit a b -> walk (pc + a : pc + b : rest) seen' m acc
                    IAssert a
                      | holds i a -> walk (pc + 1 : rest) seen' m acc
                      | otherwise -> walk rest seen' m acc
    loop i seeds =
      let (matched, consuming) = closure i seeds
       in if matched
            then True
            else
              if i >= n
                then False
                else
                  let c = at i
                      next = IS.fromList [pc + 1 | pc <- consuming, ISet rs <- [prog ! pc], inRanges rs c]
                   in loop (i + 1) next
