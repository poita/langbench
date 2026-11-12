-- | Glob patterns: compilation (with the specification's malformedness
-- rules), matching against @/@-separated candidates, and the wildcard-free
-- prefix used to narrow the candidate set of a @glob@ call.
module Kiln.Glob
  ( Pattern
  , compilePattern
  , matchPattern
  , literalPrefix
  ) where

import Data.Array (Array, listArray, (!))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.IntSet as IS
import Data.Word (Word8)

-- | A compiled glob pattern.
newtype Pattern = Pattern [Comp]
  deriving (Show)

data Comp = DoubleStar | Items [Item]
  deriving (Show)

data Item
  = AnyRun                    -- ^ @*@
  | AnyOne                    -- ^ @?@
  | Lit !Word8
  | Class !Bool [ClassItem]   -- ^ negated?, items
  deriving (Show)

data ClassItem = Single !Word8 | Range !Word8 !Word8
  deriving (Show)

slash, star, qmark, lbracket, rbracket, dash, bang :: Word8
slash = 0x2f
star = 0x2a
qmark = 0x3f
lbracket = 0x5b
rbracket = 0x5d
dash = 0x2d
bang = 0x21

-- | Compile a pattern; 'Nothing' when it is malformed.
compilePattern :: BS.ByteString -> Maybe Pattern
compilePattern pat
  | BS.null pat = Nothing
  | otherwise = Pattern <$> mapM comp (BS.split slash pat)
  where
    comp c
      | BS.null c = Nothing
      | c == "**" = Just DoubleStar
      | otherwise = Items <$> items (BS.unpack c)
    items [] = Just []
    items (c : cs)
      | c == star = (AnyRun :) <$> items cs
      | c == qmark = (AnyOne :) <$> items cs
      | c == lbracket = do
          (neg, body, rest) <- cls cs
          (Class neg body :) <$> items rest
      | otherwise = (Lit c :) <$> items cs
    cls cs = case cs of
      (b : rest) | b == bang -> (\(x, y) -> (True, x, y)) <$> classBody rest
      _ -> (\(x, y) -> (False, x, y)) <$> classBody cs
    classBody = go []
      where
        go acc xs = case xs of
          [] -> Nothing
          (c : rest)
            | c == rbracket -> if null acc then Nothing else Just (reverse acc, rest)
          (x : d : y : rest)
            | d == dash && y /= rbracket ->
                if x > y then Nothing else go (Range x y : acc) rest
          (c : rest) -> go (Single c : acc) rest

-- | A slot of the matching automaton: loops on anything (and may be skipped),
-- or consumes exactly one symbol satisfying a predicate.
data Slot a = Loop | One (a -> Bool)

-- | Run the automaton over the input.  Positions @0..m@; position @m@ accepts.
runNfa :: forall a. [Slot a] -> [a] -> Bool
runNfa slots = go start
  where
    m = length slots
    arr :: Array Int (Slot a)
    arr = listArray (0, max 0 (m - 1)) (if m == 0 then [Loop] else slots)
    isLoop p = p < m && case arr ! p of Loop -> True; One _ -> False
    close s =
      let s' = IS.union s (IS.fromList [p + 1 | p <- IS.toList s, isLoop p])
       in if IS.size s' == IS.size s then s else close s'
    start = close (IS.singleton 0)
    go s [] = IS.member m s
    go s (x : xs)
      | IS.null s = False
      | otherwise = go (close (IS.fromList (concatMap (stepFrom x) (IS.toList s)))) xs
    stepFrom x p
      | p >= m = []
      | otherwise = case arr ! p of
          Loop -> [p]
          One f -> [p + 1 | f x]

itemSlot :: Item -> Slot Word8
itemSlot AnyRun = Loop
itemSlot AnyOne = One (const True)
itemSlot (Lit c) = One (== c)
itemSlot (Class neg body) = One (\b -> any (hit b) body /= neg)
  where
    hit b (Single c) = b == c
    hit b (Range lo hi) = b >= lo && b <= hi

matchComponent :: [Item] -> BS.ByteString -> Bool
matchComponent its = runNfa (map itemSlot its) . BS.unpack

-- | Does the pattern match the whole candidate?  The candidate is split at
-- every @/@ (empty components are kept).
matchPattern :: Pattern -> BS.ByteString -> Bool
matchPattern (Pattern comps) cand = runNfa (map slot comps) parts
  where
    -- BS.split yields [] for the empty string; the spec wants one empty component.
    parts = if BS.null cand then [BS.empty] else BS.split slash cand
    slot DoubleStar = Loop
    slot (Items its) = One (matchComponent its)

-- | The longest leading run of literal bytes of a (well-formed) pattern, cut
-- back so that every matching path is guaranteed to start with it.  A path
-- such as @src@ matches @src/**@, so a trailing @/@ before a @**@ component
-- is dropped.
literalPrefix :: BS.ByteString -> BS.ByteString
literalPrefix pat
  | "/" `BS.isSuffixOf` pre && (rest == "**" || "**/" `BS.isPrefixOf` rest) = BS.init pre
  | otherwise = pre
  where
    (pre, rest) = BC.break (\c -> c == '*' || c == '?' || c == '[') pat
