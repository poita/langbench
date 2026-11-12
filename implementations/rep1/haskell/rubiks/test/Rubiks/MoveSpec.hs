module Rubiks.MoveSpec (spec) where

import Test.Hspec
import Test.QuickCheck

import Rubiks
import Rubiks.Generators

spec :: Spec
spec = do
  it "has eighteen distinct moves" $
    length (allMoves) `shouldBe` 18
  it "round-trips move indices" $
    map (moveIndex) allMoves `shouldBe` [0 .. 17]
  it "parses the eighteen tokens" $
    parseMoves "U D L R F B U' D' L' R' F' B' U2 D2 L2 R2 F2 B2"
      `shouldBe` Right
        ([Move f Clockwise | f <- [U, D, L, R, F, B]]
           ++ [Move f CounterClockwise | f <- [U, D, L, R, F, B]]
           ++ [Move f Half | f <- [U, D, L, R, F, B]])
  it "parses the empty string as no moves" $
    parseMoves "" `shouldBe` Right []
  it "rejects malformed tokens" $
    mapM_ (\t -> parseMove t `shouldSatisfy` either (const True) (const False))
      ["", "r", "R2'", "R'2", "R3", "X", "R ", "RR"]
  it "renders in standard notation" $
    renderMoves [Move R Clockwise, Move U CounterClockwise, Move F Half] `shouldBe` "R U' F2"
  it "round-trips render and parse" $
    property $ forAll genMoves $ \ms -> parseMoves (renderMoves ms) === Right ms
  it "inverts twice to the identity" $
    property $ forAll genMove $ \m -> invertMove (invertMove m) === m
  it "merges adjacent turns of one face" $ do
    fmap mergeMoves (parseMoves "R R2 U U' R' F F") `shouldBe` parseMoves "R2 F2"
    fmap mergeMoves (parseMoves "R U U' R'") `shouldBe` Right []
  it "keeps merged sequences equivalent" $
    property $ forAll genMoves $ \ms ->
      toFacelets (applyMoves (mergeMoves ms) solved) === toFacelets (applyMoves ms solved)
  it "inverts sequences" $
    property $ forAll genMoves $ \ms ->
      invertMoves (invertMoves ms) === ms
