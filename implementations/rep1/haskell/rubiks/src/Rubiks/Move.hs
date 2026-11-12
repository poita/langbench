-- |
-- Module      : Rubiks.Move
-- Description : Faces, turns and the eighteen half-turn-metric moves.
--
-- A 'Move' is a turn of one face: a clockwise quarter turn (@X@), a half turn
-- (@X2@) or a counter-clockwise quarter turn (@X'@).  Every move counts as
-- one move in the half-turn metric.
module Rubiks.Move
  ( -- * Types
    Face (..)
  , Turn (..)
  , Move (..)
    -- * Enumerating moves
  , allFaces
  , faceChar
  , charFace
  , allMoves
  , moveIndex
  , moveFromIndex
    -- * Inverses
  , invertMove
  , invertMoves
  , mergeMoves
    -- * Text notation
  , renderMove
  , renderMoves
  , parseMove
  , parseMoves
  ) where

import Data.Char (isSpace)

-- | The six faces, named by the direction they point in.
data Face = U | R | F | D | L | B
  deriving (Eq, Ord, Show, Read, Enum, Bounded)

-- | How far a face is turned.
data Turn
  = Clockwise         -- ^ a quarter turn clockwise (@X@)
  | Half              -- ^ a half turn (@X2@)
  | CounterClockwise  -- ^ a quarter turn counter-clockwise (@X'@)
  deriving (Eq, Ord, Show, Read, Enum, Bounded)

-- | A turn of a face.  Clockwise is as seen looking at that face from outside.
data Move = Move !Face !Turn
  deriving (Eq, Ord, Show, Read)

-- | All six faces.
allFaces :: [Face]
allFaces = [minBound .. maxBound]

-- | The letter naming a face.
faceChar :: Face -> Char
faceChar f = case f of
  U -> 'U'
  R -> 'R'
  F -> 'F'
  D -> 'D'
  L -> 'L'
  B -> 'B'

-- | Inverse of 'faceChar'.
charFace :: Char -> Maybe Face
charFace c = lookup c [(faceChar f, f) | f <- allFaces]

-- | All eighteen moves, in the order of 'moveIndex'.
allMoves :: [Move]
allMoves = map moveFromIndex [0 .. 17]

-- | A dense index in @[0, 17]@: @3 * fromEnum face + fromEnum turn@.
moveIndex :: Move -> Int
moveIndex (Move f t) = 3 * fromEnum f + fromEnum t

-- | Inverse of 'moveIndex'.  The argument must be in @[0, 17]@.
moveFromIndex :: Int -> Move
moveFromIndex i
  | i >= 0 && i < 18 = Move (toEnum q) (toEnum r)
  | otherwise = error ("moveFromIndex: out of range: " ++ show i)
  where
    (q, r) = i `divMod` 3

-- | The move that undoes the given one.
invertMove :: Move -> Move
invertMove (Move f Clockwise) = Move f CounterClockwise
invertMove (Move f CounterClockwise) = Move f Clockwise
invertMove m@(Move _ Half) = m

-- | The sequence that undoes the given one.
invertMoves :: [Move] -> [Move]
invertMoves = reverse . map invertMove

-- | Combine adjacent turns of the same face (@R R2@ becomes @R'@, @R R'@
-- disappears), repeatedly.  Never lengthens a sequence.
mergeMoves :: [Move] -> [Move]
mergeMoves = reverse . foldl' push []
  where
    push (Move f t : rest) (Move g u)
      | f == g = case (quarters t + quarters u) `mod` 4 of
          0 -> rest
          n -> Move f (fromQuarters n) : rest
    push acc m = m : acc
    quarters t = fromEnum t + 1
    fromQuarters n = toEnum (n - 1)

-- | Standard notation: @U@, @U'@, @U2@.
renderMove :: Move -> String
renderMove (Move f t) = faceChar f : suffix
  where
    suffix = case t of
      Clockwise -> ""
      Half -> "2"
      CounterClockwise -> "'"

-- | Render a sequence of moves separated by single spaces.
renderMoves :: [Move] -> String
renderMoves = unwords . map renderMove

-- | Parse one token such as @R@, @R'@ or @R2@.
parseMove :: String -> Either String Move
parseMove tok = case tok of
  [c] -> face c Clockwise
  [c, '\''] -> face c CounterClockwise
  [c, '2'] -> face c Half
  _ -> Left ("invalid move: " ++ show tok)
  where
    face c t = maybe (Left ("invalid move: " ++ show tok)) (\f -> Right (Move f t)) (charFace c)

-- | Parse whitespace-separated move tokens.  The empty string is the empty
-- sequence.
parseMoves :: String -> Either String [Move]
parseMoves = mapM parseMove . words'
  where
    words' s = case dropWhile isSpace s of
      "" -> []
      s' -> let (w, rest) = break isSpace s' in w : words' rest
