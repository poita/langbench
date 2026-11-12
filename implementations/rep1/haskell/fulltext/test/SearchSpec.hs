{-# LANGUAGE OverloadedStrings #-}
module SearchSpec (spec) where

import qualified Data.IntMap.Strict as IntMap
import Data.Text (Text)
import Test.Hspec

import Fulltext.Index
import Fulltext.Query
import Fulltext.Search

ix :: Index
ix = buildIndex
  [ ("d1", "cat dog bird")
  , ("d2", "cat cat cat fish")
  , ("d3", "dog fish")
  , ("d4", "aa aa aa aa")
  , ("d5", "") ]

-- | Matching documents of a query, in rank order.
run :: Int -> Text -> [DocIx]
run k q = map hitDoc (search ix k (parseQuery q))

spec :: Spec
spec = do
  describe "atomMatches" $ do
    it "matches a phrase by adjacency" $
      atomMatches ix (Atom ["cat", "dog"]) `shouldBe` IntMap.fromList [(0, [0])]
    it "does not match terms in the wrong order" $
      atomMatches ix (Atom ["dog", "cat"]) `shouldBe` IntMap.empty
    it "counts overlapping occurrences" $
      atomMatches ix (Atom ["aa", "aa"]) `shouldBe` IntMap.fromList [(3, [0, 1, 2])]
    it "matches three-term phrases" $
      atomMatches ix (Atom ["cat", "dog", "bird"]) `shouldBe` IntMap.fromList [(0, [0])]
    it "never crosses document boundaries" $
      atomMatches ix (Atom ["bird", "cat"]) `shouldBe` IntMap.empty
    it "matches nothing when a term is unknown" $
      atomMatches ix (Atom ["cat", "zebra"]) `shouldBe` IntMap.empty

  describe "search" $ do
    it "returns documents containing the atom" $ run 10 "dog" `shouldMatchList` [0, 2]
    it "ranks by term frequency, then length normalisation" $
      take 1 (run 10 "cat") `shouldBe` [1]
    it "breaks ties by document id" $ run 10 "fish dog" `shouldBe` [2]
    it "implements AND" $ run 10 "cat AND dog" `shouldBe` [0]
    it "implements OR" $ run 10 "bird OR fish" `shouldMatchList` [0, 1, 2]
    it "implements NOT over the whole corpus, empty documents included" $
      run 10 "NOT cat" `shouldMatchList` [2, 3, 4]
    it "scores negative-only matches 0" $
      map hitScore (search ix 10 (parseQuery "NOT cat")) `shouldBe` [0, 0, 0]
    it "matches nothing for the empty tree" $ run 10 "()" `shouldBe` []
    it "honours k" $ length (run 2 "dog OR cat OR fish") `shouldBe` 2
    it "gives tied documents in id order" $ do
      let tied = buildIndex [("z", "same words"), ("a", "same words"), ("m", "same words")]
      map hitDoc (search tied 10 (parseQuery "same")) `shouldBe` [0, 1, 2]
    it "scores like the BM25 formula" $ do
      -- one document, N = 1, df = 1, f = 1, |d| = avgdl -> 1 * ln(4/3)
      let one = buildIndex [("note", "quick brown fox")]
      case search one 10 (parseQuery "fox") of
        [h] -> hitScore h `shouldSatisfy` \s -> abs (s - log (4 / 3)) < 1e-12
        other -> expectationFailure (show (length other))
    it "reports occurrences of positive atoms only" $
      case search ix 10 (parseQuery "cat NOT bird") of
        [h] -> hitOccurrences h `shouldBe` [(1, [0, 1, 2])]
        other -> expectationFailure (show (length other))
