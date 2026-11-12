module QuerySpec (spec) where

import Data.Either (isLeft)
import Test.Hspec

import Chess.Perft

spec :: Spec
spec = do
  describe "parseQuery" $ do
    it "parses perft and divide queries" $ do
      fmap isPerft (parseQuery (startFen' ++ " 3")) `shouldBe` Right True
      fmap isPerft (parseQuery (startFen' ++ " divide 2")) `shouldBe` Right False
    it "rejects malformed lines" $ do
      parseQuery startFen' `shouldSatisfy` isLeft
      parseQuery (startFen' ++ " x") `shouldSatisfy` isLeft
      parseQuery (startFen' ++ " divid 2") `shouldSatisfy` isLeft
  describe "processInput" $ do
    it "answers perft queries in order" $
      processInput (unlines
        [ startFen' ++ " 1"
        , startFen' ++ " 3"
        , "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1 0" ])
        `shouldBe` Right "20\n8902\n1\n"
    it "produces empty output for empty input" $
      processInput "" `shouldBe` Right ""
    it "does not need a trailing newline" $
      processInput (startFen' ++ " 1") `shouldBe` Right "20\n"
    it "prints divide output sorted, with a total" $
      processInput "8/P1k5/K7/8/8/8/8/8 w - - 0 1 divide 1\n"
        `shouldBe` Right (unlines
          ["a6a5 1", "a6b5 1", "a7a8b 1", "a7a8n 1", "a7a8q 1", "a7a8r 1", "total 6"])
    it "prints just a total when there are no moves" $
      processInput "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1 divide 3\n" `shouldBe` Right "total 0\n"
    it "divides at depth 2 with castling" $
      fmap (take 3 . lines) (processInput "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1 divide 2\n")
        `shouldBe` Right ["a1a2 25", "a1a3 24", "a1a4 23"]
    it "reports the first malformed line" $
      processInput "garbage\n" `shouldSatisfy` isLeft
  where
    startFen' = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    isPerft (PerftQuery _ _) = True
    isPerft _ = False
