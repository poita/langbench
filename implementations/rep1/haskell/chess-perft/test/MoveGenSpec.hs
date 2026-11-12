module MoveGenSpec (spec, positions, walk, bruteForce) where

import Data.Maybe (isNothing)
import Data.List (nub, sort)
import Test.Hspec
import Test.QuickCheck

import Chess.Perft

-- | FENs used as starting points for random walks.
positions :: [Position]
positions =
  [ either error id (parseFen f)
  | f <-
      [ startFen
      , "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"
      , "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1"
      , "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1"
      , "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8"
      ]
  ]

-- | Play up to @length picks@ moves, choosing by index.
walk :: Position -> [Int] -> [Position]
walk pos [] = [pos]
walk pos (i : is) = case legalMoves pos of
  [] -> [pos]
  ms -> pos : walk (makeMove pos (ms !! (i `mod` length ms))) is

-- | An independent, deliberately naive generator: enumerate pseudo-legal moves
-- square by square with coordinate arithmetic, then keep those after which
-- the mover's king is not attacked (found by actually playing the move).
bruteForce :: Position -> [Move]
bruteForce pos = filter legal (concatMap fromSquare [0 .. 63])
  where
    us = posSideToMove pos
    legal m = not (isKingAttacked (makeMove pos m) us)
    at f r
      | f < 0 || f > 7 || r < 0 || r > 7 = Nothing
      | otherwise = Just (mkSquare f r)
    fromSquare sq = case pieceAt pos sq of
      Just (c, pt) | c == us -> pieceMoves sq pt
      _ -> []
    f0 sq = fileOf sq
    r0 sq = rankOf sq
    steps sq ds = [ (t, pieceAt pos t) | (df, dr) <- ds, Just t <- [at (f0 sq + df) (r0 sq + dr)] ]
    stepMoves sq ds =
      [ mkMove sq t | (t, occ) <- steps sq ds, maybe True ((/= us) . fst) occ ]
    slide sq ds =
      [ mkMove sq t
      | (df, dr) <- ds
      , t <- takeRay (f0 sq) (r0 sq) df dr ]
    takeRay f r df dr = case at (f + df) (r + dr) of
      Nothing -> []
      Just t -> case pieceAt pos t of
        Nothing -> t : takeRay (f + df) (r + dr) df dr
        Just (c, _) -> [t | c /= us]
    orth = [(1, 0), (-1, 0), (0, 1), (0, -1)]
    diag = [(1, 1), (1, -1), (-1, 1), (-1, -1)]
    pieceMoves sq pt = case pt of
      Knight -> stepMoves sq [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)]
      Bishop -> slide sq diag
      Rook -> slide sq orth
      Queen -> slide sq (orth ++ diag)
      King -> stepMoves sq (orth ++ diag) ++ castling sq
      Pawn -> pawnMoves sq
    dir = if us == White then 1 else -1
    pawnMoves sq =
      let f = f0 sq
          r = r0 sq
          lastRank = if us == White then 7 else 0
          startRank = if us == White then 1 else 6
          promote from to
            | r0 to == lastRank = [mkPromotion from to p | p <- [Queen, Rook, Bishop, Knight]]
            | otherwise = [mkMove from to]
          one = at f (r + dir)
          two = at f (r + 2 * dir)
          pushes = case one of
            Just t | isNothing (pieceAt pos t) ->
              promote sq t
                ++ [ mkMove sq t2 | r == startRank, Just t2 <- [two], isNothing (pieceAt pos t2) ]
            _ -> []
          caps = concat
            [ promote sq t
            | df <- [-1, 1], Just t <- [at (f + df) (r + dir)]
            , maybe False ((/= us) . fst) (pieceAt pos t) ]
          eps = [ mkMove sq t
                | df <- [-1, 1], Just t <- [at (f + df) (r + dir)]
                , enPassantSquare pos == Just t ]
       in pushes ++ caps ++ eps
    castling sq =
      let home = if us == White then 0 else 7
          empty f = isNothing (pieceAt pos (mkSquare f home))
          crossOk f = not (isKingAttacked (makeMove pos (mkMove sq (mkSquare f home))) us)
          has = hasCastlingRight (posCastling pos) us
       in if sq /= mkSquare 4 home || inCheck pos then [] else
            [ mkMove sq (mkSquare 6 home) | has KingSide, empty 5, empty 6, crossOk 5 ]
              ++ [ mkMove sq (mkSquare 2 home) | has QueenSide, empty 1, empty 2, empty 3, crossOk 3 ]

movesOf :: String -> [String]
movesOf fen = sort (map moveToUci (legalMoves (either error id (parseFen fen))))

spec :: Spec
spec = do
  describe "legalMoves" $ do
    it "finds the 20 opening moves" $
      length (legalMoves startPosition) `shouldBe` 20
    it "generates four promotions per promoting push" $
      movesOf "8/P1k5/K7/8/8/8/8/8 w - - 0 1"
        `shouldBe` ["a6a5", "a6b5", "a7a8b", "a7a8n", "a7a8q", "a7a8r"]
    it "finds no moves in stalemate or checkmate" $ do
      movesOf "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1" `shouldBe` []
      movesOf "R6k/6pp/8/8/8/8/8/K7 b - - 0 1" `shouldBe` []
    it "allows only king moves in double check" $
      movesOf "4k3/8/8/8/1b6/5n2/8/R3K2R w - - 0 1"
        `shouldBe` ["e1d1", "e1e2", "e1f1", "e1f2"]
    it "forbids stepping back along a checking slider's line" $
      movesOf "4k3/8/8/8/8/8/8/r3K3 w - - 0 1" `shouldNotSatisfy` elem "e1f1"
    it "resolves check by capture or block only" $
      movesOf "4k3/8/8/b7/8/8/7R/4K3 w - - 0 1"
        `shouldBe` ["e1d1", "e1e2", "e1f1", "e1f2", "h2d2"]
    it "pins pieces to the king" $ do
      -- the e2 bishop is pinned along the e-file and cannot move at all
      movesOf "4r1k1/8/8/8/8/8/4B3/4K3 w - - 0 1" `shouldBe` ["e1d1", "e1d2", "e1f1", "e1f2"]
      -- a pinned rook may slide along the pin and capture the pinner
      movesOf "4r1k1/8/8/8/8/8/4R3/4K3 w - - 0 1"
        `shouldBe` ["e1d1", "e1d2", "e1f1", "e1f2", "e2e3", "e2e4", "e2e5", "e2e6", "e2e7", "e2e8"]
    describe "castling" $ do
      it "is available when unobstructed" $
        movesOf "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1" `shouldSatisfy` (\ms -> "e1g1" `elem` ms && "e1c1" `elem` ms)
      it "is not allowed out of, through or into check" $ do
        movesOf "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1" `shouldSatisfy` ("e1g1" `elem`)
        movesOf "4k3/8/8/8/8/8/5r2/R3K2R w KQ - 0 1" `shouldSatisfy` (\ms -> "e1g1" `notElem` ms && "e1c1" `elem` ms)
        movesOf "4k3/8/8/8/8/8/6r1/R3K2R w KQ - 0 1" `shouldSatisfy` (\ms -> "e1g1" `notElem` ms && "e1c1" `elem` ms)
        movesOf "4k3/8/8/8/8/8/3r4/R3K2R w KQ - 0 1" `shouldSatisfy` (\ms -> "e1c1" `notElem` ms && "e1g1" `elem` ms)
        movesOf "4k3/8/8/8/8/8/4r3/R3K2R w KQ - 0 1" `shouldSatisfy` (\ms -> "e1g1" `notElem` ms && "e1c1" `notElem` ms)
      it "tolerates an attacked b-file square or rook" $
        movesOf "1r2k2r/8/8/8/8/8/8/R3K2R w KQ - 0 1" `shouldSatisfy` ("e1c1" `elem`)
      it "needs the squares between king and rook to be empty" $
        movesOf "4k3/8/8/8/8/8/8/RN2K2R w KQ - 0 1" `shouldSatisfy` ("e1c1" `notElem`)
    describe "en passant" $ do
      it "is generated for an adjacent pawn" $
        movesOf "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1" `shouldSatisfy` ("e5d6" `elem`)
      it "yields nothing when no pawn can capture" $
        length (movesOf "4k3/8/8/8/3p4/8/8/4K3 w - d6 0 1") `shouldBe` 5
      it "is illegal when it exposes the king along the rank" $
        movesOf "8/8/8/K2pP2r/8/8/8/7k w - d6 0 1" `shouldNotSatisfy` elem "e5d6"
      it "is legal when it captures a checking pawn" $
        movesOf "8/8/8/2k5/3Pp3/8/8/4K3 b - d3 0 1" `shouldSatisfy` ("e4d3" `elem`)
  describe "properties" $ do
    it "countLegalMoves agrees with the length of legalMoves" $
      property $ \(Positive k) is ->
        let ps = walk (positions !! (k `mod` length positions)) (take 30 is)
         in all (\p -> countLegalMoves p == length (legalMoves p)) ps
    it "generates distinct moves" $
      property $ \(Positive k) is ->
        let ps = walk (positions !! (k `mod` length positions)) (take 30 is)
         in all (\p -> let ms = legalMoves p in length (nub ms) == length ms) ps
    it "never leaves the mover's king attacked" $
      property $ \(Positive k) is ->
        let ps = walk (positions !! (k `mod` length positions)) (take 30 is)
         in and [ not (isKingAttacked (makeMove p m) (posSideToMove p))
                | p <- ps, m <- legalMoves p ]
    it "agrees with brute-force legality (pseudo-legal moves filtered by playing them)" $
      property $ \(Positive k) is ->
        let ps = walk (positions !! (k `mod` length positions)) (take 20 is)
         in all (\p -> sort (map moveToUci (legalMoves p)) == sort (map moveToUci (bruteForce p))) ps
