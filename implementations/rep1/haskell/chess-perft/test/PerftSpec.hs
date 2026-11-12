module PerftSpec (spec) where

import Data.List (sort)
import Test.Hspec
import Test.QuickCheck

import Chess.Perft
import MoveGenSpec (positions, walk)

fen :: String -> Position
fen = either error id . parseFen

kiwipete, pos3, pos4, pos5, pos6 :: Position
kiwipete = fen "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"
pos3 = fen "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1"
pos4 = fen "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1"
pos5 = fen "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8"
pos6 = fen "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10"

check :: Position -> [Int] -> Spec
check pos expected =
  it (toFen pos) $ map (`perft` pos) [1 .. length expected] `shouldBe` expected

spec :: Spec
spec = do
  describe "reference values" $ do
    check startPosition [20, 400, 8902, 197281]
    check kiwipete [48, 2039, 97862]
    check pos3 [14, 191, 2812, 43238, 674624]
    check pos4 [6, 264, 9467, 422333]
    check pos5 [44, 1486, 62379]
    check pos6 [46, 2079, 89890]
  describe "perft" $ do
    it "is 1 at depth 0" $ perft 0 startPosition `shouldBe` 1
    it "is 0 in checkmate and stalemate" $ do
      perft 3 (fen "R6k/6pp/8/8/8/8/8/K7 b - - 0 1") `shouldBe` 0
      perft 1 (fen "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1") `shouldBe` 0
  describe "divide" $ do
    it "is sorted by UCI string and sums to perft" $
      property $ \(Positive k) (Positive d) ->
        let pos = positions !! (k `mod` length positions)
            depth = 1 + d `mod` 3
            res = divide depth pos
            names = map (moveToUci . fst) res
         in names == sort names && sum (map snd res) == perft depth pos
    it "satisfies perft d = sum of perft (d-1) over children along random walks" $
      property $ \(Positive k) is ->
        let ps = walk (positions !! (k `mod` length positions)) (take 4 is)
         in all (\p -> perft 3 p == sum [perft 2 (makeMove p m) | m <- legalMoves p]) ps
    it "lists the divide of the start position at depth 1" $
      length (divide 1 startPosition) `shouldBe` 20
