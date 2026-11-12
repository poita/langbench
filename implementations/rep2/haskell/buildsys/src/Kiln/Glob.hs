-- | Glob patterns as used by @glob@, @filter@ and @reject@.
--
-- Matching is a simulation of a nondeterministic automaton, so it costs
-- O(pattern × candidate) with no backtracking.
module Kiln.Glob
  ( Pattern
  , compilePattern
  , matchPattern
  , literalPrefix
  ) where

import Data.Array
import qualified Data.ByteString as B
import qualified Data.IntSet as IS
import Data.Word (Word8)

data Item
  = IStar
  | IAny
  | IClass !Bool [(Word8, Word8)]
  | ILit !Word8

data Comp = CStarStar | CItems !Int (Array Int Item)

-- | A compiled pattern.
data Pattern = Pattern
  { patComps :: !Int
  , patArr :: Array Int Comp
  , patPrefix :: B.ByteString
  }

slash :: Word8
slash = 47

-- | Compile a pattern; 'Nothing' if it is malformed.
compilePattern :: B.ByteString -> Maybe Pattern
compilePattern pat
  | B.null pat = Nothing
  | otherwise = do
      let parts = B.split slash pat
      comps <- mapM compileComp parts
      let n = length comps
      pure Pattern
        { patComps = n
        , patArr = listArray (0, n - 1) comps
        , patPrefix = prefixOf pat parts
        }

-- | The wildcard-free prefix that every matching candidate starts with. A
-- trailing @/@ before a @**@ component is dropped, since @**@ matches zero
-- components (@src/**@ matches @src@).
prefixOf :: B.ByteString -> [B.ByteString] -> B.ByteString
prefixOf pat _ =
  let pre = B.takeWhile (\b -> b /= 42 && b /= 63 && b /= 91) pat
      rest = B.drop (B.length pre) pat
   in if B.isSuffixOf "/" pre && B.isPrefixOf "**" rest
        then B.init pre
        else pre

literalPrefix :: Pattern -> B.ByteString
literalPrefix = patPrefix

compileComp :: B.ByteString -> Maybe Comp
compileComp comp
  | B.null comp = Nothing
  | comp == "**" = Just CStarStar
  | otherwise = do
      items <- items' (B.unpack comp)
      let n = length items
      pure (CItems n (listArray (0, n - 1) items))
  where
    items' [] = Just []
    items' (b : bs)
      | b == 42 = (IStar :) <$> items' bs
      | b == 63 = (IAny :) <$> items' bs
      | b == 91 = do
          let (neg, bs') = case bs of
                (33 : r) -> (True, r)
                _ -> (False, bs)
          (rs, rest) <- classItems bs' []
          if null rs then Nothing else (IClass neg rs :) <$> items' rest
      | otherwise = (ILit b :) <$> items' bs
    classItems [] _ = Nothing
    classItems (93 : rest) acc = Just (reverse acc, rest)
    classItems (x : 45 : y : rest) acc
      | y /= 93 = if x > y then Nothing else classItems rest ((x, y) : acc)
    classItems (x : rest) acc = classItems rest ((x, x) : acc)

-- | Does the pattern match the whole candidate? The candidate is split at
-- every @/@ and empty components are kept.
matchPattern :: Pattern -> B.ByteString -> Bool
matchPattern (Pattern n arr _) cand =
  IS.member n (foldl step (closure (IS.singleton 0)) comps)
  where
    comps = if B.null cand then [B.empty] else B.split slash cand
    closure s = foldl (\acc i -> if IS.member i acc && isSS i then IS.insert (i + 1) acc else acc) s [0 .. n - 1]
    isSS i = case arr ! i of CStarStar -> True; _ -> False
    step states c =
      closure . IS.fromList $
        concat
          [ case arr ! i of
              CStarStar -> [i]
              CItems k items -> [i + 1 | matchItems k items c]
          | i <- IS.toList states
          , i < n
          ]

matchItems :: Int -> Array Int Item -> B.ByteString -> Bool
matchItems k items s = IS.member k (B.foldl' step (closure (IS.singleton 0)) s)
  where
    closure st = foldl (\acc i -> if IS.member i acc && isStar i then IS.insert (i + 1) acc else acc) st [0 .. k - 1]
    isStar i = case items ! i of IStar -> True; _ -> False
    step states b =
      closure . IS.fromList $
        concat
          [ case items ! i of
              IStar -> [i]
              IAny -> [i + 1]
              ILit x -> [i + 1 | x == b]
              IClass neg rs ->
                [i + 1 | any (\(lo, hi) -> lo <= b && b <= hi) rs /= neg]
          | i <- IS.toList states
          , i < k
          ]
