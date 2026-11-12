{-# LANGUAGE OverloadedStrings #-}
module SnippetSpec (spec) where

import Data.List (maximumBy)
import qualified Data.Text as T
import Data.Ord (comparing)
import Test.Hspec
import Test.QuickCheck

import Fulltext.Index
import Fulltext.Snippet

-- | Direct evaluation of every window, as in the specification.
naive :: Int -> [(Int, [Int])] -> Int
naive len atoms
  | len <= windowSize = 0
  | otherwise = snd (maximumBy (comparing fst <> comparing (negate . snd))
                       [ (score s, s) | s <- [0 .. len - windowSize] ])
  where
    inside s n p = p >= s && p + n - 1 <= s + windowSize - 1
    score s = ( length [ () | (n, ps) <- atoms, any (inside s n) ps ]
              , sum [ 1 :: Int | (n, ps) <- atoms, p <- ps, inside s n p ] )

-- | Random valid occurrence lists for a document of the given length.
genAtoms :: Int -> Gen [(Int, [Int])]
genAtoms len = listOf $ do
  n <- elements [1, 2, 3, 29, 30, 31]
  ps <- if n > len then pure [] else sublistOf [0 .. len - n]
  pure (n, ps)

spec :: Spec
spec = do
  describe "bestWindow" $ do
    it "is 0 for short documents" $ bestWindow 30 [(1, [29])] `shouldBe` 0
    it "is 0 without occurrences" $ bestWindow 100 [] `shouldBe` 0
    it "prefers more distinct atoms" $
      -- two atoms fit together only in windows 11..40; the most occurrences
      -- of the first atom alone would favour window 0
      bestWindow 100 [(1, [10, 11, 12]), (1, [40])] `shouldBe` 11
    it "prefers more occurrences, then the smaller start" $
      bestWindow 100 [(1, [10, 50, 51])] `shouldBe` 22
    it "ignores atoms longer than the window" $
      bestWindow 100 [(31, [5])] `shouldBe` 0
    it "agrees with window-by-window evaluation" $
      property $ forAll (choose (0, 120)) $ \len ->
        forAll (genAtoms len) $ \atoms -> bestWindow len atoms === naive len atoms

  describe "snippet" $ do
    it "collapses whitespace" $
      collapseSpace "a \t\n b\xA0\xA0\&c" `shouldBe` "a b c"
    it "uses the whole document when it is short" $ do
      let ix = buildIndex [("d", "  The quick\n\nbrown fox.  ")]
      snippet (document ix 0) [] `shouldBe` "The quick brown fox"
    it "is empty for a document with no tokens" $ do
      let ix = buildIndex [("d", "  ... ")]
      snippet (document ix 0) [] `shouldBe` ""
    it "centres on the densest window" $ do
      let ws = [ T.pack ("w" ++ show i) | i <- [0 .. 99 :: Int] ]
          ix = buildIndex [("d", T.unwords ws)]
          s = snippet (document ix 0) [(1, [60])]
      -- smallest start whose window contains position 60 is 31
      T.words s `shouldBe` take 30 (drop 31 ws)
    it "has no layout characters" $
      property $ \(t :: String) ->
        let ix = buildIndex [("d", T.pack t)]
            s = snippet (document ix 0) []
        in not (T.any (`elem` ("\t\n\r\v\f" :: String)) s)
