-- |
-- Module      : TextBuffer.Movement
-- Description : Moving a single cursor.
module TextBuffer.Movement
  ( moveCursor
  ) where

import Data.Maybe (fromMaybe)

import TextBuffer.Command (Direction (..))
import TextBuffer.Cursor
import TextBuffer.Document
import TextBuffer.Position

-- | @moveCursor dir extend doc c@ moves one cursor. The result is not
-- normalized and, except for 'MoveUp' / 'MoveDown', its goal column is
-- stale: the caller resets goals once the whole command is done.
moveCursor :: Direction -> Bool -> Document -> Cursor -> Cursor
moveCursor dir extend doc c
  | not extend, hasSelection c, Just p <- collapse = pointCursor' p
  | otherwise = finish headMoved
  where
    start = rangeStart c
    end = rangeEnd c
    primary = curPrimary c
    pointCursor' p = c { curHead = p, curAnchor = Nothing }
    collapse = case dir of
      MoveLeft  -> Just start
      MoveRight -> Just end
      _         -> Nothing
    base | extend    = fromMaybe (curHead c) (curAnchor c)
         | otherwise = curHead c
    (newHead, newGoal) = step doc dir (curHead c) (curGoal c)
    headMoved = (newHead, newGoal)
    finish (h, g)
      | extend, h /= base = Cursor h (Just base) primary g
      | otherwise         = Cursor h Nothing primary g

-- | Move a head position, returning the new head and goal column.
step :: Document -> Direction -> Pos -> Int -> (Pos, Int)
step doc dir p@(Pos l c) goal = case dir of
  MoveLeft
    | c > 0     -> (Pos l (c - 1), goal)
    | l > 0     -> (Pos (l - 1) (lineLength doc (l - 1)), goal)
    | otherwise -> (p, goal)
  MoveRight
    | c < lineLength doc l       -> (Pos l (c + 1), goal)
    | l < lineCount doc - 1      -> (Pos (l + 1) 0, goal)
    | otherwise                  -> (p, goal)
  MoveHome -> (Pos l 0, goal)
  MoveEnd  -> (Pos l (lineLength doc l), goal)
  MoveUp
    | l == 0    -> (origin, 0)
    | otherwise -> (Pos (l - 1) (min goal (lineLength doc (l - 1))), goal)
  MoveDown
    | l == lineCount doc - 1 -> let e = endOfDocument doc in (e, posCol e)
    | otherwise -> (Pos (l + 1) (min goal (lineLength doc (l + 1))), goal)
