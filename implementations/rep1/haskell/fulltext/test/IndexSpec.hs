{-# LANGUAGE OverloadedStrings #-}
module IndexSpec (spec) where

import Test.Hspec

import Fulltext.Index

spec :: Spec
spec = do
  let ix = buildIndex
        [ ("b", "The cat sat. The cat ran.")
        , ("a", "A dog barked at the cat")
        , ("empty", "") ]
  it "orders documents by id" $ map docId (documents ix) `shouldBe` ["a", "b", "empty"]
  it "counts documents and tokens (stop words included)" $ do
    numDocs ix `shouldBe` 3
    totalTokens ix `shouldBe` 6 + 6
    map docLength (documents ix) `shouldBe` [6, 6, 0]
  it "computes the mean length" $ avgDocLength ix `shouldBe` 4
  it "counts distinct terms, stop words included" $
    -- a dog bark at the cat sat ran  (the stem of "barked" is "bark")
    numTerms ix `shouldBe` 8
  it "records sorted positions per document" $
    termPostings ix "cat" `shouldBe` [(0, [5]), (1, [1, 4])]
  it "returns no postings for unknown terms" $ termPostings ix "zebra" `shouldBe` []
  it "stores stemmed terms" $ termPostings ix "bark" `shouldBe` [(0, [2])]
  it "keeps token spans" $ tokenSpan (document ix 1) 4 `shouldBe` (17, 20)
  it "handles an empty corpus" $ do
    let e = buildIndex []
    numDocs e `shouldBe` 0
    avgDocLength e `shouldBe` 0
    numTerms e `shouldBe` 0
  it "round-trips keys" $ do
    keyDoc (mkKey 7 123456) `shouldBe` 7
    keyPos (mkKey 7 123456) `shouldBe` 123456
