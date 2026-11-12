-- |
-- Module      : Fulltext.Search
-- Description : Phrase matching, boolean evaluation, BM25 scoring and ranking.
module Fulltext.Search
  ( Hit (..)
  , Matches
  , atomMatches
  , search
  , bm25K1
  , bm25B
  ) where

import Data.List (sortBy)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import qualified Data.Map.Strict as Map
import Data.Ord (Down (..), comparing)

import Fulltext.Index
import Fulltext.Query

-- | BM25 term-saturation parameter.
bm25K1 :: Double
bm25K1 = 1.2

-- | BM25 length-normalisation parameter.
bm25B :: Double
bm25B = 0.75

-- | A ranked document.
data Hit = Hit
  { hitDoc   :: !DocIx
  , hitScore :: !Double
  , hitOccurrences :: [(Int, [Int])]
    -- ^ for every positive atom occurring in the document: its length in
    -- terms and its sorted start positions (computed lazily)
  }

-- | For each document containing an atom, the sorted start positions of its
-- occurrences.
type Matches = IntMap [Int]

-- | Match a phrase atom by positional intersection of its terms' postings.
-- All lists are sorted, so each step is one linear merge.
atomMatches :: Index -> Atom -> Matches
atomMatches ix (Atom ts) = case mapM (lookupTerm ix) ts of
  Nothing -> IntMap.empty
  Just [] -> IntMap.empty
  Just (t0 : rest) ->
    let starts = foldl' (\cur (i, t) -> shiftMerge i cur (termKeys ix t)) (termKeys ix t0) (zip [1 ..] rest)
    in IntMap.fromDistinctAscList (groupKeys starts)

-- | Keep the keys @x@ of the first list for which @x + i@ is in the second.
shiftMerge :: Int -> [Int] -> [Int] -> [Int]
shiftMerge i = go
  where
    go xs@(x : xs') ys@(y : ys') = case compare (x + i) y of
      EQ -> x : go xs' ys'
      LT -> go xs' ys
      GT -> go xs ys'
    go _ _ = []

-- | Evaluate a query and return the best @k@ documents, ranked by BM25 score
-- (descending) then document id.  The empty tree matches nothing.
search :: Index -> Int -> Maybe Query -> [Hit]
search _ _ Nothing = []
search ix k (Just q) = map toHit (take k ranked)
  where
    n = numDocs ix
    nD = fromIntegral n :: Double
    avgdl = avgDocLength ix
    matches = Map.fromList [ (a, atomMatches ix a) | a <- allAtoms q ]
    universe = IntSet.fromDistinctAscList [0 .. n - 1]

    eval :: Query -> IntSet
    eval t = case t of
      QAtom a -> IntMap.keysSet (matches Map.! a)
      QNot x -> IntSet.difference universe (eval x)
      QAnd xs -> foldl1 IntSet.intersection (map eval xs)
      QOr xs -> foldl1 IntSet.union (map eval xs)

    positives =
      [ (atomLength a, m, idf (IntMap.size m))
      | a <- positiveAtoms q, let m = matches Map.! a ]
    idf df = log ((nD - fromIntegral df + 0.5) / (fromIntegral df + 0.5) + 1)

    score d =
      let dl = fromIntegral (docLength (document ix d)) :: Double
          norm = if avgdl == 0 then 0 else dl / avgdl
          term acc (_, m, w) = case IntMap.lookup d m of
            Nothing -> acc
            Just ps ->
              let f = fromIntegral (length ps)
              in acc + w * ((f * (bm25K1 + 1)) / (f + bm25K1 * (1 - bm25B + bm25B * norm)))
      in foldl' term 0 positives

    ranked = sortBy (comparing (Down . snd) <> comparing fst)
               [ (d, score d) | d <- IntSet.toAscList (eval q) ]

    toHit (d, s) = Hit d s [ (len, ps) | (len, m, _) <- positives, Just ps <- [IntMap.lookup d m] ]
