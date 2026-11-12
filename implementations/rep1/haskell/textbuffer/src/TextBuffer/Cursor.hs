-- |
-- Module      : TextBuffer.Cursor
-- Description : Cursors, selections and normalization.
module TextBuffer.Cursor
  ( Cursor (..)
  , pointCursor
  , hasSelection
  , rangeStart
  , rangeEnd
  , isBackward
  , normalize
  , resetGoals
  ) where

import Data.List (sortBy)
import Data.Maybe (isJust)

import TextBuffer.Position

-- | A caret with an optional selection.
data Cursor = Cursor
  { curHead    :: !Pos
    -- ^ where the caret is
  , curAnchor  :: !(Maybe Pos)
    -- ^ the other end of the selection; never equal to the head
  , curPrimary :: !Bool
    -- ^ exactly one cursor of a buffer is primary
  , curGoal    :: !Int
    -- ^ goal column used by vertical movement
  } deriving (Eq, Show)

-- | A cursor with no selection, whose goal column is its column.
pointCursor :: Bool -> Pos -> Cursor
pointCursor primary p = Cursor p Nothing primary (posCol p)

-- | Does the cursor hold a selection?
hasSelection :: Cursor -> Bool
hasSelection = isJust . curAnchor

-- | The smaller end of the cursor's range.
rangeStart :: Cursor -> Pos
rangeStart (Cursor h Nothing _ _) = h
rangeStart (Cursor h (Just a) _ _) = min h a

-- | The larger end of the cursor's range.
rangeEnd :: Cursor -> Pos
rangeEnd (Cursor h Nothing _ _) = h
rangeEnd (Cursor h (Just a) _ _) = max h a

-- | Is the selection backward (head at the start)? False without selection.
isBackward :: Cursor -> Bool
isBackward c = hasSelection c && curHead c == rangeStart c

-- | Sort cursors by range start (ties: larger end first, then stable) and
-- merge colliding cursors in one sweep. See the specification for the
-- precise rules.
normalize :: [Cursor] -> [Cursor]
normalize cs = case sortBy cmp cs of
  []       -> []
  (c : rest) -> sweep c rest
  where
    cmp a b = compare (rangeStart a) (rangeStart b)
              <> compare (rangeEnd b) (rangeEnd a)
    sweep cur [] = [cur]
    sweep cur (c : rest)
      | joins cur c = sweep (merge cur c) rest
      | otherwise   = cur : sweep c rest
    joins cur c
      | hasSelection cur && hasSelection c = rangeStart c < rangeEnd cur
      | otherwise                          = rangeStart c <= rangeEnd cur
    merge cur c
      | s == e    = Cursor s Nothing primary (curGoal cur)
      | isBackward cur = Cursor s (Just e) primary (curGoal cur)
      | otherwise = Cursor e (Just s) primary (curGoal cur)
      where
        s = rangeStart cur
        e = max (rangeEnd cur) (rangeEnd c)
        primary = curPrimary cur || curPrimary c

-- | Set every cursor's goal column to the column of its head.
resetGoals :: [Cursor] -> [Cursor]
resetGoals = map (\c -> c { curGoal = posCol (curHead c) })
