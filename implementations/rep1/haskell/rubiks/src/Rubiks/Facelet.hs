-- |
-- Module      : Rubiks.Facelet
-- Description : The 54-sticker model of the cube.
--
-- Each face carries nine stickers ("facelets") numbered 1-9 in reading order
-- as seen looking at that face from outside.  The unfolded cube is
--
-- >              +----------+
-- >              | U1 U2 U3 |
-- >              | U4 U5 U6 |
-- >              | U7 U8 U9 |
-- >   +----------+----------+----------+----------+
-- >   | L1 L2 L3 | F1 F2 F3 | R1 R2 R3 | B1 B2 B3 |
-- >   | L4 L5 L6 | F4 F5 F6 | R4 R5 R6 | B4 B5 B6 |
-- >   | L7 L8 L9 | F7 F8 F9 | R7 R8 R9 | B7 B8 B9 |
-- >   +----------+----------+----------+----------+
-- >              | D1 D2 D3 |
-- >              | D4 D5 D6 |
-- >              | D7 D8 D9 |
-- >              +----------+
--
-- A facelet is identified by an index in @[0, 53]@: @9 * fromEnum face + n - 1@.
-- A cube is described by the colour (named by the face whose centre carries
-- it) of each of the 54 facelets.
--
-- This module is the ground truth for the move definitions: 'Rubiks.Cube'
-- derives its cubie-level moves from the facelet cycles here.
module Rubiks.Facelet
  ( Facelets
  , faceletIndex
  , faceletName
  , solvedFacelets
  , applyFaceletMove
  , applyFaceletMoves
  , cornerFacelets
  , edgeFacelets
  , renderFacelets
  ) where

import Data.Array qualified as A
import Data.Array.Unboxed (UArray, listArray, (!))
import Data.Char (digitToInt)
import Data.Maybe (fromMaybe)

import Rubiks.Move

-- | The colour of each of the 54 facelets, indexed by 'faceletIndex'.
type Facelets = [Face]

-- | Index of facelet @n@ (1-9) of a face.
faceletIndex :: Face -> Int -> Int
faceletIndex f n = 9 * fromEnum f + n - 1

-- | Inverse of 'faceletIndex', e.g. @\"U1\"@.
faceletName :: Int -> String
faceletName i = faceChar (toEnum (i `div` 9)) : show (i `mod` 9 + 1)

-- | The solved cube: every facelet matches its face.
solvedFacelets :: Facelets
solvedFacelets = [f | f <- allFaces, _ <- [1 .. 9 :: Int]]

-- | Parse a facelet name like @\"R7\"@.
nameToIndex :: String -> Int
nameToIndex [c, d] =
  case charFace c of
    Just f | d >= '1' && d <= '9' -> faceletIndex f (digitToInt d)
    _ -> error ("bad facelet name: " ++ [c, d])
nameToIndex s = error ("bad facelet name: " ++ s)

-- | Parse the cycle notation @(a b c d)(...)@ used in the specification.
parseCycles :: String -> [[Int]]
parseCycles = go
  where
    go s = case dropWhile (/= '(') s of
      [] -> []
      (_ : rest) ->
        let (body, rest') = break (== ')') rest
         in map nameToIndex (words body) : go rest'

-- | Quarter-turn clockwise cycles of each face: the sticker at the first
-- facelet of a cycle moves to the second, and so on.
quarterCycles :: Face -> String
quarterCycles f = case f of
  U -> "(U1 U3 U9 U7)(U2 U6 U8 U4)(F1 L1 B1 R1)(F2 L2 B2 R2)(F3 L3 B3 R3)"
  D -> "(D1 D3 D9 D7)(D2 D6 D8 D4)(F7 R7 B7 L7)(F8 R8 B8 L8)(F9 R9 B9 L9)"
  R -> "(R1 R3 R9 R7)(R2 R6 R8 R4)(F3 U3 B7 D3)(F6 U6 B4 D6)(F9 U9 B1 D9)"
  L -> "(L1 L3 L9 L7)(L2 L6 L8 L4)(F1 D1 B9 U1)(F4 D4 B6 U4)(F7 D7 B3 U7)"
  F -> "(F1 F3 F9 F7)(F2 F6 F8 F4)(U7 R1 D3 L9)(U8 R4 D2 L6)(U9 R7 D1 L3)"
  B -> "(B1 B3 B9 B7)(B2 B6 B8 B4)(U3 L1 D7 R9)(U2 L4 D8 R6)(U1 L7 D9 R3)"

-- | @source ! i@ is the facelet whose sticker lands on facelet @i@.
type Source = UArray Int Int

quarterSource :: Face -> Source
quarterSource f = listArray (0, 53) [fromMaybe i (lookup i moves) | i <- [0 .. 53]]
  where
    moves =
      [ (b, a)
      | cyc <- parseCycles (quarterCycles f)
      , (a, b) <- zip cyc (drop 1 cyc ++ take 1 cyc)
      ]

-- | Apply one move to a facelet colouring.
applyFaceletMove :: Move -> Facelets -> Facelets
applyFaceletMove (Move f t) fl = iterate step fl !! n
  where
    src = quarterSource f
    step cur = let arr = A.listArray (0, 53) cur :: A.Array Int Face in [arr A.! (src ! i) | i <- [0 .. 53]]
    n = case t of
      Clockwise -> 1
      Half -> 2
      CounterClockwise -> 3 :: Int

-- | Apply moves left to right.
applyFaceletMoves :: [Move] -> Facelets -> Facelets
applyFaceletMoves ms fl = foldl (flip applyFaceletMove) fl ms

-- | The facelets of the eight corner positions, each in clockwise order as
-- seen from outside the cube, starting with the U/D-face facelet.
cornerFacelets :: [[Int]]
cornerFacelets =
  map (map nameToIndex . words)
    ["U9 R1 F3", "U7 F1 L3", "U1 L1 B3", "U3 B1 R3", "D3 F9 R7", "D1 L9 F7", "D7 B9 L7", "D9 R9 B7"]

-- | The facelets of the twelve edge positions.  The first facelet of each pair
-- is on the U/D face for the eight U/D-layer edges and on the F/B face for the
-- four middle-layer edges.
edgeFacelets :: [[Int]]
edgeFacelets =
  map (map nameToIndex . words)
    [ "U6 R2", "U8 F2", "U4 L2", "U2 B2", "D6 R8", "D2 F8", "D4 L8", "D8 B8"
    , "F6 R4", "F4 L6", "B6 L4", "B4 R6" ]

-- | Draw the cube as an unfolded net (for debugging and examples).
renderFacelets :: Facelets -> String
renderFacelets fl = unlines (concat [top, middle, bottom])
  where
    at f n = faceChar (fl !! faceletIndex f n)
    row f r = [at f (3 * r + c) | c <- [1 .. 3]]
    pad = replicate 4 ' '
    top = [pad ++ row U r | r <- [0 .. 2]]
    middle = [unwords [row f r | f <- [L, F, R, B]] | r <- [0 .. 2]]
    bottom = [pad ++ row D r | r <- [0 .. 2]]
