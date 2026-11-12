module Rubiks.Generators
  ( genMove
  , genMoves
  , genScramble
  , superflipMoves
  , singleFlippedEdge
  ) where

import Data.Array.Unboxed (listArray)
import Test.QuickCheck

import Rubiks

genMove :: Gen Move
genMove = elements allMoves

genMoves :: Gen [Move]
genMoves = sized $ \n -> do
  k <- choose (0, min 40 n)
  vectorOf k genMove

-- | Scrambles of a fixed length, as in the scramble generator of the tests.
genScramble :: Int -> Gen [Move]
genScramble n = vectorOf n genMove

-- | A move sequence that produces the superflip.
superflipMoves :: [Move]
superflipMoves = either error id (parseMoves "U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2")

-- | A cube with exactly one edge flipped: not solvable.
singleFlippedEdge :: Cube
singleFlippedEdge = solved {edgeOri = listArray (0, 11) (1 : replicate 11 0)}
