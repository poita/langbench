-- |
-- Module      : Fulltext.Snippet
-- Description : Best-window snippet extraction.
module Fulltext.Snippet
  ( windowSize
  , bestWindow
  , snippet
  , collapseSpace
  ) where

import Control.Monad (forM_, when)
import Control.Monad.ST (ST, runST)
import Data.Array.ST (STUArray, newArray, readArray, writeArray)
import Data.Text (Text)
import qualified Data.Text as T

import Fulltext.Analysis (isSpaceChar)
import Fulltext.Index

-- | The window length @W@, in tokens.
windowSize :: Int
windowSize = 30

-- | The start of the best window of a document of the given length.  The
-- occurrences are given per positive atom as @(atom length, sorted start
-- positions)@.  The best window has the most distinct atoms inside it, then
-- the most occurrences, then the smallest start.
--
-- Runs in O(length + occurrences) using difference arrays over the window
-- starts: an occurrence at @p@ of an atom of @n@ terms is inside exactly the
-- windows whose start lies in @[max 0 (p+n-W), min p (L-W)]@.
bestWindow :: Int -> [(Int, [Int])] -> Int
bestWindow len atoms
  | len <= windowSize = 0
  | otherwise = runST $ do
      let smax = len - windowSize
      distinct <- newArray (0, smax + 1) 0 :: ST s (STUArray s Int Int)
      total <- newArray (0, smax + 1) 0 :: ST s (STUArray s Int Int)
      let add arr lo hi = do
            a <- readArray arr lo
            writeArray arr lo (a + 1)
            b <- readArray arr (hi + 1)
            writeArray arr (hi + 1) (b - 1)
      forM_ atoms $ \(n, ps) -> when (n <= windowSize) $ do
        let go _ [] = pure ()
            go covered (p : rest) = do
              let lo = max 0 (p + n - windowSize)
                  hi = min p smax
                  lo' = max lo (covered + 1)
              add total lo hi
              when (lo' <= hi) $ add distinct lo' hi
              go (max covered hi) rest
        go (-1 :: Int) ps
      let sweep s !d !t !best !bd !bt
            | s > smax = pure best
            | otherwise = do
                dd <- readArray distinct s
                tt <- readArray total s
                let d' = d + dd
                    t' = t + tt
                if (d', t') > (bd, bt)
                  then sweep (s + 1) d' t' s d' t'
                  else sweep (s + 1) d' t' best bd bt
      sweep 0 0 0 0 (-1) (-1)

-- | Build the snippet of a document from the occurrences of the positive
-- atoms: the text from the first token of the best window to its last token,
-- with whitespace runs collapsed.
snippet :: Document -> [(Int, [Int])] -> Text
snippet doc occs
  | len == 0 = T.empty
  | otherwise =
      let s = bestWindow len occs
          (start, _) = tokenSpan doc s
          (_, end) = tokenSpan doc (min (s + windowSize) len - 1)
      in collapseSpace (T.take (end - start) (T.drop start (docText doc)))
  where len = docLength doc

-- | Replace every maximal run of the seven whitespace characters by one space.
collapseSpace :: Text -> Text
collapseSpace = T.pack . go . T.unpack
  where
    go [] = []
    go (c : cs)
      | isSpaceChar c = ' ' : go (dropWhile isSpaceChar cs)
      | otherwise = c : go cs
