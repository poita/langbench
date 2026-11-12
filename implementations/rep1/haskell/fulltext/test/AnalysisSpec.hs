{-# LANGUAGE OverloadedStrings #-}
module AnalysisSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec
import Test.QuickCheck

import Fulltext.Analysis

toks :: Text -> [Text]
toks = map tokText . tokenize

spec :: Spec
spec = do
  describe "tokenize" $ do
    let cases =
          [ ("The cat sat.", ["the", "cat", "sat"])
          , ("don't stop", ["dont", "stop"])
          , ("'quoted'", ["quoted"])
          , ("rock'n'roll", ["rocknroll"])
          , ("a''b", ["a", "b"])
          , ("well-known", ["well", "known"])
          , ("Version 1.2.3", ["version", "1", "2", "3"])
          , ("X1 XY2Z", ["x1", "xy2z"])
          , ("Don\x2019t", ["dont"])
          , ("Caf\xE9 CAF\xC9", ["caf\xE9", "caf\xC9"])
          , ("3 \xD7 4 \xF7 2", ["3", "4", "2"])
          , ("\x4E2D\x6587 abc", ["abc"])
          , ("", [])
          ] :: [(Text, [Text])]
    mapM_ (\(i, o) -> it (show i) $ toks i `shouldBe` o) cases

    it "reports code-point spans" $
      map (\t -> (tokStart t, tokEnd t)) (tokenize "ab \x2019\&x don't")
        `shouldBe` [(0, 2), (4, 5), (6, 11)]

    it "counts astral characters as one code point" $
      map (\t -> (tokStart t, tokEnd t)) (tokenize "\x1F600 ab")
        `shouldBe` [(2, 4)]

    it "produces ordered, disjoint, non-empty tokens inside the text" $
      property $ \(s :: String) ->
        let txt = T.pack s
            ts = tokenize txt
            ok (a, b) = a < b && b <= T.length txt
        in all (ok . (\t -> (tokStart t, tokEnd t))) ts
           && and (zipWith (\a b -> tokEnd a < tokStart b) ts (drop 1 ts))
           && all (not . T.null . tokText) ts

    it "never puts apostrophes or upper-case ASCII in token text" $
      property $ \(s :: String) ->
        all (T.all (\c -> not (isApostrophe c) && not (c >= 'A' && c <= 'Z')) . tokText)
            (tokenize (T.pack s))

  describe "stop words" $ do
    it "has exactly 33 members" $ length stopWords `shouldBe` 33
    it "recognises stop words" $ all isStopWord ["the", "a", "with", "their"] `shouldBe` True
    it "rejects others" $ any isStopWord ["cat", "The", "i"] `shouldBe` False

  describe "termOf" $ do
    it "stems pure a-z tokens" $ termOf "running" `shouldBe` "run"
    it "leaves tokens with digits alone" $ termOf "running2" `shouldBe` "running2"
    it "leaves non-ASCII tokens alone" $ termOf "caf\xE9s" `shouldBe` "caf\xE9s"
