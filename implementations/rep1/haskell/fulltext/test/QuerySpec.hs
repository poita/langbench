{-# LANGUAGE OverloadedStrings #-}
module QuerySpec (spec) where

import Data.Text (Text)
import Test.Hspec

import Fulltext.Query

a :: Text -> Query
a w = QAtom (Atom [w])

spec :: Spec
spec = do
  let p = parseQuery
      cat = Just (a "cat")
  describe "parseQuery" $ do
    it "treats juxtaposition as AND" $
      p "cat dog" `shouldBe` Just (QAnd [a "cat", a "dog"])
    it "gives NOT the tightest binding" $
      p "cat OR dog NOT bird" `shouldBe`
        Just (QOr [a "cat", QAnd [a "dog", QNot (a "bird")]])
    it "honours parentheses" $
      p "(cat OR dog) AND bird" `shouldBe`
        Just (QAnd [QOr [a "cat", a "dog"], a "bird"])
    it "parses phrases as multi-term atoms" $
      p "\"the big cat\"" `shouldBe` Just (QAtom (Atom ["the", "big", "cat"]))
    it "splits hyphenated bare words into a phrase" $
      p "well-known" `shouldBe` Just (QAtom (Atom ["well", "known"]))
    it "stems the terms" $ p "running" `shouldBe` Just (a "run")
    it "stacks NOTs" $ p "NOT NOT cat" `shouldBe` Just (QNot (QNot (a "cat")))
    it "treats lower-case operators as words" $
      p "cat or dog" `shouldBe` Just (QAnd [a "cat", a "dog"])

    describe "recovery" $ do
      mapM_ (\q -> it (show q ++ " is just cat") $ p q `shouldBe` cat)
        [ "cat AND", "OR cat", "cat ()", "cat NOT ()", "cat NOT (", "(cat"
        , "\"cat", "cat ) dog", "cat ) ) dog", "((cat))" ]
      mapM_ (\q -> it (show q ++ " is empty") $ p q `shouldBe` Nothing)
        [ "()", "the", "NOT", "", "\"\"", "AND OR", "!!!" ]
      it "absorbs adjacent operators (OR AND)" $
        p "cat OR AND dog" `shouldBe` Just (QOr [a "cat", a "dog"])
      it "absorbs adjacent operators (AND OR)" $
        p "cat AND OR dog" `shouldBe` Just (QOr [a "cat", a "dog"])
      it "collapses AND AND" $
        p "cat AND AND dog" `shouldBe` Just (QAnd [a "cat", a "dog"])
      it "reads an unterminated group" $
        p "dog NOT ( cat" `shouldBe` Just (QAnd [a "dog", QNot (a "cat")])

    describe "atoms" $ do
      it "drops single stop-word atoms but keeps them inside phrases" $
        p "\"to be\"" `shouldBe` Just (QAtom (Atom ["to", "be"]))
      it "drops a quoted single stop word" $ p "\"the\"" `shouldBe` Nothing

  describe "positiveAtoms" $ do
    let pos = maybe [] positiveAtoms . p
    it "excludes negated atoms" $ pos "cat NOT dog" `shouldBe` [Atom ["cat"]]
    it "counts double negation as positive" $
      pos "NOT NOT cat" `shouldBe` [Atom ["cat"]]
    it "keeps first-seen order and drops duplicates" $
      pos "dog cat dog" `shouldBe` [Atom ["dog"], Atom ["cat"]]
    it "is empty for a purely negative query" $ pos "NOT cat" `shouldBe` []
    it "flips parity through nested groups" $
      pos "NOT (a1 AND NOT b1)" `shouldBe` [Atom ["b1"]]
