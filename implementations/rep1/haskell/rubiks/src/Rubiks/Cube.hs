-- |
-- Module      : Rubiks.Cube
-- Description : Cubie-level model of the 3x3x3 cube.
--
-- A cube is described by where its eight corner and twelve edge pieces are
-- and how each is twisted or flipped.
--
-- __Numbering.__  Corner /positions/ (and the pieces that start in them) are
-- numbered in the order of 'Rubiks.Facelet.cornerFacelets':
-- URF, UFL, ULB, UBR, DFR, DLF, DBL, DRB (named by the faces whose facelets
-- are listed).  Edge positions follow 'Rubiks.Facelet.edgeFacelets':
-- UR, UF, UL, UB, DR, DF, DL, DB, FR, FL, BL, BR.  Edges 8-11 are the
-- middle-layer ("E-slice") edges.
--
-- __Orientation.__  A corner's orientation is the index (0, 1, 2) of the
-- facelet of its position that carries the piece's U/D-colour sticker; an
-- edge's orientation is the index (0, 1) of the facelet that carries the
-- piece's first-listed colour (U/D colour for U/D-layer edges, F/B colour for
-- middle-layer edges).  With this convention quarter turns of @F@ and @B@ are
-- exactly the moves that flip edges, and turns of @U@ and @D@ never twist
-- corners' U/D stickers off the U/D faces.
module Rubiks.Cube
  ( Cube (..)
  , solved
  , isSolved
    -- * Moves
  , applyMove
  , applyMoves
  , compose
  , moveCube
    -- * Facelet conversion
  , toFacelets
  , fromFacelets
    -- * Validity
  , isSolvable
  ) where

import Data.Array (Array)
import Data.Array qualified as A
import Data.Array.Unboxed (UArray, elems, listArray, (!))

import Rubiks.Facelet
import Rubiks.Internal.Combinatorics (permutationParity)
import Rubiks.Move

-- | A cube state.  For position @i@, @cornerPerm ! i@ is the piece sitting
-- there and @cornerOri ! i@ its twist; likewise for edges.
data Cube = Cube
  { cornerPerm :: !(UArray Int Int)
  , cornerOri :: !(UArray Int Int)
  , edgePerm :: !(UArray Int Int)
  , edgeOri :: !(UArray Int Int)
  }
  deriving (Eq, Ord, Show)

-- | The solved cube.
solved :: Cube
solved =
  Cube
    { cornerPerm = listArray (0, 7) [0 .. 7]
    , cornerOri = listArray (0, 7) (replicate 8 0)
    , edgePerm = listArray (0, 11) [0 .. 11]
    , edgeOri = listArray (0, 11) (replicate 12 0)
    }

-- | Is every piece home and untwisted?
isSolved :: Cube -> Bool
isSolved = (== solved)

-- | @compose a b@ is the cube reached by doing everything that produced @a@
-- and then everything that produced @b@ (starting from solved).
compose :: Cube -> Cube -> Cube
compose a b =
  Cube
    { cornerPerm = listArray (0, 7) [cornerPerm a ! j | j <- cb]
    , cornerOri = listArray (0, 7) [(cornerOri a ! j + cornerOri b ! i) `mod` 3 | (i, j) <- zip [0 ..] cb]
    , edgePerm = listArray (0, 11) [edgePerm a ! j | j <- eb]
    , edgeOri = listArray (0, 11) [(edgeOri a ! j + edgeOri b ! i) `mod` 2 | (i, j) <- zip [0 ..] eb]
    }
  where
    cb = elems (cornerPerm b)
    eb = elems (edgePerm b)

-- | The cube obtained by applying a single move to a solved cube.  Derived
-- from the facelet cycles of the specification.
moveCube :: Move -> Cube
moveCube m = moveTable A.! moveIndex m

moveTable :: Array Int Cube
moveTable = A.listArray (0, 17) [build (moveFromIndex i) | i <- [0 .. 17]]
  where
    build (Move f t) =
      let q = quarter f
          h = compose q q
       in case t of
            Clockwise -> q
            Half -> h
            CounterClockwise -> compose h q
    quarter f = case fromFacelets (applyFaceletMove (Move f Clockwise) solvedFacelets) of
      Right c -> c
      Left e -> error ("Rubiks.Cube: bad move definition: " ++ e)

-- | Apply one move.
applyMove :: Move -> Cube -> Cube
applyMove m c = compose c (moveCube m)

-- | Apply moves left to right.
applyMoves :: [Move] -> Cube -> Cube
applyMoves ms c = foldl' (flip applyMove) c ms

-- | The colours of the facelets of a cube.
toFacelets :: Cube -> Facelets
toFacelets c = [faceAt A.! i | i <- [0 .. 53]]
  where
    faceAt = A.array (0, 53) placed :: Array Int Face
    placed = centres ++ corners ++ edges
    centres = [(faceletIndex f 5, f) | f <- allFaces]
    corners =
      [ (facelet, colour)
      | (pos, slots) <- zip [0 ..] cornerFacelets
      , let piece = cornerPerm c ! pos
            o = cornerOri c ! pos
            home = map faceOf (cornerFacelets !! piece)
      , (k, colour) <- zip [0 ..] home
      , let facelet = slots !! ((o + k) `mod` 3)
      ]
    edges =
      [ (facelet, colour)
      | (pos, slots) <- zip [0 ..] edgeFacelets
      , let piece = edgePerm c ! pos
            o = edgeOri c ! pos
            home = map faceOf (edgeFacelets !! piece)
      , (k, colour) <- zip [0 ..] home
      , let facelet = slots !! ((o + k) `mod` 2)
      ]

-- | The face a facelet index belongs to (its colour on a solved cube).
faceOf :: Int -> Face
faceOf i = toEnum (i `div` 9)

-- | Read a cube off its facelet colouring.  Fails if some corner or edge
-- does not show a combination of colours that exists on a real cube.  The
-- result may still be unsolvable; see 'isSolvable'.
fromFacelets :: Facelets -> Either String Cube
fromFacelets fl
  | length fl /= 54 = Left "expected 54 facelets"
  | otherwise = do
      cs <- mapM (locate cornerFacelets 3) [0 .. 7]
      es <- mapM (locate edgeFacelets 2) [0 .. 11]
      let c =
            Cube
              { cornerPerm = listArray (0, 7) (map fst cs)
              , cornerOri = listArray (0, 7) (map snd cs)
              , edgePerm = listArray (0, 11) (map fst es)
              , edgeOri = listArray (0, 11) (map snd es)
              }
      if distinct (map fst cs) && distinct (map fst es)
        then Right c
        else Left "a piece occurs more than once"
  where
    arr = listArray (0, 53) (map fromEnum fl) :: UArray Int Int
    colourAt i = toEnum (arr ! i) :: Face
    distinct xs = and [length (filter (== x) xs) == 1 | x <- [0 .. length xs - 1]]
    -- Find which piece, in which orientation, occupies a position.
    locate table n pos =
      let seen = map colourAt (table !! pos)
          matches =
            [ (piece, o)
            | (piece, homeSlots) <- zip [0 ..] table
            , let home = map faceOf homeSlots
            , o <- [0 .. n - 1]
            , and [seen !! ((o + k) `mod` n) == h | (k, h) <- zip [0 ..] home]
            ]
       in case matches of
            [m] -> Right m
            _ -> Left ("invalid piece at position " ++ show pos)

-- | Can the cube be solved by legal moves?  Requires a valid piece
-- permutation, total corner twist divisible by 3, total edge flip even, and
-- equal corner and edge permutation parity.
isSolvable :: Cube -> Bool
isSolvable c =
  isPerm 8 cp
    && isPerm 12 ep
    && sum (elems (cornerOri c)) `mod` 3 == 0
    && sum (elems (edgeOri c)) `mod` 2 == 0
    && permutationParity cp == permutationParity ep
  where
    cp = elems (cornerPerm c)
    ep = elems (edgePerm c)
    isPerm n xs = length xs == n && all (`elem` xs) [0 .. n - 1]
