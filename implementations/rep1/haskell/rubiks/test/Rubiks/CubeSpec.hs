module Rubiks.CubeSpec (spec) where

import Data.Array.Unboxed (elems)
import Test.Hspec
import Test.QuickCheck

import Rubiks
import Rubiks.Generators

moves :: String -> [Move]
moves = either error id . parseMoves

-- | Order of a move sequence: smallest k > 0 with seq^k = identity.
order :: [Move] -> Int
order ms = length (takeWhile (not . isSolved) (drop 1 (iterate (applyMoves ms) solved))) + 1

spec :: Spec
spec = do
  describe "model sanity checks from the specification" $ do
    it "every basic move has order 4 (and its inverse/double behave)" $
      mapM_ (\f -> do
               order [Move f Clockwise] `shouldBe` 4
               order [Move f Half] `shouldBe` 2
               applyMoves [Move f Clockwise, Move f CounterClockwise] solved `shouldBe` solved)
        allFaces
    it "R U R' U' has order 6" $ order (moves "R U R' U'") `shouldBe` 6
    it "R U has order 105" $ order (moves "R U") `shouldBe` 105
    it "U D has order 4" $ order (moves "U D") `shouldBe` 4
    it "the specification's sequence produces the superflip" $ do
      let c = applyMoves superflipMoves solved
      elems (cornerPerm c) `shouldBe` [0 .. 7]
      elems (cornerOri c) `shouldBe` replicate 8 0
      elems (edgePerm c) `shouldBe` [0 .. 11]
      elems (edgeOri c) `shouldBe` replicate 12 1
    it "U on a solved cube moves colours as described" $ do
      let fl = toFacelets (applyMove (Move U Clockwise) solved)
          at f n = fl !! faceletIndex f n
      [at F n | n <- [1, 2, 3]] `shouldBe` [R, R, R]
      [at L n | n <- [1, 2, 3]] `shouldBe` [F, F, F]
      [at B n | n <- [1, 2, 3]] `shouldBe` [L, L, L]
      [at R n | n <- [1, 2, 3]] `shouldBe` [B, B, B]
  describe "facelet model" $ do
    it "solved cube is the solved facelets" $ toFacelets solved `shouldBe` solvedFacelets
    it "round-trips through facelets" $
      property $ forAll genMoves $ \ms ->
        let c = applyMoves ms solved in fromFacelets (toFacelets c) === Right c
    it "cubie moves agree with the facelet cycles" $
      property $ forAll genMoves $ \ms ->
        toFacelets (applyMoves ms solved) === applyFaceletMoves ms solvedFacelets
    it "rejects an impossible colouring" $ do
      let bad = take 53 solvedFacelets ++ [U]
      fromFacelets bad `shouldSatisfy` either (const True) (const False)
      fromFacelets (take 10 solvedFacelets) `shouldSatisfy` either (const True) (const False)
  describe "solvability" $ do
    it "is preserved by moves" $
      property $ forAll genMoves $ \ms -> isSolvable (applyMoves ms solved)
    it "fails for a single flipped edge" $
      isSolvable singleFlippedEdge `shouldBe` False
  describe "composition" $ do
    it "applying a sequence equals composing its parts" $
      property $ forAll genMoves $ \a -> forAll genMoves $ \b ->
        applyMoves (a ++ b) solved === compose (applyMoves a solved) (applyMoves b solved)
    it "a sequence followed by its inverse is the identity" $
      property $ forAll genMoves $ \ms ->
        isSolved (applyMoves (ms ++ invertMoves ms) solved)
