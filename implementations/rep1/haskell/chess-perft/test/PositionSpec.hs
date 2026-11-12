module PositionSpec (spec) where

import Data.Either (isLeft)
import Test.Hspec

import Chess.Perft

spec :: Spec
spec = do
  describe "parseFen / toFen" $ do
    it "round-trips well-known positions" $
      mapM_ roundTrip
        [ startFen
        , "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"
        , "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1"
        , "rnbqkbnr/pppp1ppp/8/8/3Pp3/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 1"
        ]
    it "ignores the halfmove and fullmove counters" $
      fmap toFen (parseFen "8/8/8/8/8/8/8/K6k w - - 17 99")
        `shouldBe` Right "8/8/8/8/8/8/8/K6k w - - 0 1"
    it "places pieces on the expected squares" $ do
      pieceAt startPosition 0 `shouldBe` Just (White, Rook)
      pieceAt startPosition 4 `shouldBe` Just (White, King)
      pieceAt startPosition 12 `shouldBe` Just (White, Pawn)
      pieceAt startPosition 27 `shouldBe` Nothing
      pieceAt startPosition 59 `shouldBe` Just (Black, Queen)
    it "reads side, castling and en passant fields" $ do
      let pos = fen "rnbqkbnr/pppp1ppp/8/8/3Pp3/8/PPP1PPPP/RNBQKBNR b Kq d3 0 1"
      posSideToMove pos `shouldBe` Black
      castlingToString (posCastling pos) `shouldBe` "Kq"
      fmap squareName (enPassantSquare pos) `shouldBe` Just "d3"
    it "drops castling rights without king and rook in place" $ do
      let pos = fen "r3k2r/8/8/8/8/8/8/R3K1N1 w KQkq - 0 1"
      castlingToString (posCastling pos) `shouldBe` "Qkq"
    it "drops an en passant square with no pawn behind it" $ do
      let pos = fen "8/8/8/8/8/8/8/K6k w - e6 0 1"
      enPassantSquare pos `shouldBe` Nothing
    it "rejects malformed input" $ do
      parseFen "" `shouldSatisfy` isLeft
      parseFen "8/8/8/8/8/8/8/8 w - - 0 1" `shouldSatisfy` isLeft          -- no kings
      parseFen "8/8/8/8/8/8/8/K6k x - - 0 1" `shouldSatisfy` isLeft        -- bad side
      parseFen "8/8/8/8/8/8/8/K7k w - - 0 1" `shouldSatisfy` isLeft        -- rank too long
      parseFen "P7/8/8/8/8/8/8/K6k w - - 0 1" `shouldSatisfy` isLeft       -- pawn on rank 8
      parseFen "R6k/8/8/8/8/8/8/K7 w - - 0 1" `shouldSatisfy` isLeft       -- black in check, white to move
  describe "squares and moves" $ do
    it "names squares" $ do
      map squareName [0, 7, 63, 28] `shouldBe` ["a1", "h1", "h8", "e4"]
      parseSquare "e4" `shouldBe` Just 28
      parseSquare "i4" `shouldBe` Nothing
    it "prints moves in UCI notation" $ do
      moveToUci (mkMove 12 28) `shouldBe` "e2e4"
      moveToUci (mkPromotion 48 56 Knight) `shouldBe` "a7a8n"
      movePromotion (mkPromotion 48 56 Queen) `shouldBe` Just Queen
      movePromotion (mkMove 12 28) `shouldBe` Nothing
  describe "makeMove" $ do
    it "plays a double pawn push and sets the en passant square" $ do
      let pos = makeMove startPosition (mkMove 12 28)
      toFen pos `shouldBe` "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"
    it "castles, moving the rook and clearing both rights" $ do
      let pos = fen "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"
      toFen (makeMove pos (mkMove 4 6)) `shouldBe` "r3k2r/8/8/8/8/8/8/R4RK1 b kq - 0 1"
      toFen (makeMove pos (mkMove 4 2)) `shouldBe` "r3k2r/8/8/8/8/8/8/2KR3R b kq - 0 1"
    it "removes the pawn captured en passant" $ do
      let pos = fen "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1"
      toFen (makeMove pos (mkMove 36 43)) `shouldBe` "4k3/8/3P4/8/8/8/8/4K3 b - - 0 1"
    it "loses the right when a rook is captured on its corner by a promotion" $ do
      let pos = fen "r3k2r/1P6/8/8/8/8/8/4K3 w kq - 0 1"
      toFen (makeMove pos (mkPromotion 49 56 Queen)) `shouldBe` "Q3k2r/8/8/8/8/8/8/4K3 b k - 0 1"
  describe "attacks" $ do
    it "detects check" $ do
      let pos = fen "4k3/8/8/8/8/8/4r3/4K3 w - - 0 1"
      inCheck pos `shouldBe` True
      inCheck startPosition `shouldBe` False
  where
    fen = either error id . parseFen
    roundTrip f = fmap toFen (parseFen f) `shouldBe` Right f
