{-# LANGUAGE OverloadedStrings #-}
module EndToEndSpec (spec) where

import qualified Data.Text as T
import Test.Hspec

import Fulltext
import Fulltext.Corpus
import Fulltext.Report

render :: [(T.Text, T.Text)] -> T.Text -> (T.Text, T.Text)
render docs qs =
  let ix = buildIndex docs
      out = [ (j, runQuery ix (jobLimit j) (jobText j)) | j <- parseQueryFile qs ]
  in (renderResults out, renderStats ix)

spec :: Spec
spec = do
  it "reproduces the worked example of the specification" $ do
    let (res, st) = render [("note", "The quick brown fox jumps over the lazy dog.\n")]
                           "fox\nquick brown\ncat\n\"lazy dog\"\n"
        sn = "The quick brown fox jumps over the lazy dog"
    res `shouldBe` T.unlines
      [ "QUERY 1 fox", "HITS 1", "1\tnote\t0.2877\t" <> sn
      , "QUERY 2 quick brown", "HITS 1", "1\tnote\t0.5754\t" <> sn
      , "QUERY 3 cat", "HITS 0"
      , "QUERY 4 \"lazy dog\"", "HITS 1", "1\tnote\t0.2877\t" <> sn ]
    st `shouldBe` T.unlines ["documents 1", "tokens 9", "terms 8", "avgdl 9.0000"]

  it "ranks by frequency and breaks ties by id" $ do
    let (res, _) = render [ ("copy1", "alpha beta gamma"), ("copy2", "alpha beta gamma")
                          , ("copy3", "alpha beta gamma"), ("other", "alpha alpha beta") ]
                          "alpha"
    res `shouldBe` T.unlines
      [ "QUERY 1 alpha", "HITS 4"
      , "1\tother\t0.1449\talpha alpha beta"
      , "2\tcopy1\t0.1054\talpha beta gamma"
      , "3\tcopy2\t0.1054\talpha beta gamma"
      , "4\tcopy3\t0.1054\talpha beta gamma" ]

  it "writes an empty snippet field for empty documents" $ do
    let (res, _) = render [("e", "")] "NOT zebra"
    res `shouldBe` "QUERY 1 NOT zebra\nHITS 1\n1\te\t0.0000\t\n"

  it "describes an empty corpus" $ do
    let (res, st) = render [] "cat\n"
    res `shouldBe` "QUERY 1 cat\nHITS 0\n"
    st `shouldBe` T.unlines ["documents 0", "tokens 0", "terms 0", "avgdl 0.0000"]

  it "formats scores with four decimals" $ do
    formatScore 0 `shouldBe` "0.0000"
    formatScore 1.23456 `shouldBe` "1.2346"
