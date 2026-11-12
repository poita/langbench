-- | Vertical items, the units the paginator works with.
module Typeset.Vertical
  ( GroupKind (..)
  , HeadInfo (..)
  , VLine (..)
  , VItem (..)
  , FigBlock (..)
  , Stats (..)
  , noStats
  , addStats
  ) where

import Typeset.Line (Run, SetLine)

-- | Whether a line group is a heading (kept together and with the next
-- block) or anything else.
data GroupKind = GHeading | GOther
  deriving (Eq, Show)

-- | What the paginator and the table of contents need to know about a
-- heading; carried by its first line.
data HeadInfo = HeadInfo
  { hiLevel :: !Int
  , hiStar :: !Bool
  , hiNumber :: String   -- ^ number string, empty when unnumbered
  , hiPlain :: String    -- ^ plain text
  } deriving (Show)

-- | One placed line of a vertical list.
data VLine = VLine
  { vlRuns :: [Run]
  , vlAscent :: !Int
  , vlDepth :: !Int
  , vlLeading :: !Int
  , vlGroup :: !Int
  , vlIndex :: !Int      -- ^ 1-based position in its group
  , vlGroupSize :: !Int
  , vlKind :: !GroupKind
  , vlNotes :: [Int]
  , vlHead :: Maybe HeadInfo
  } deriving (Show)

-- | A vertical item.
data VItem
  = VLineI VLine
  | VGlue !Int
  | VRule !Int !Int !Int                 -- ^ x, width, thickness
  | VRow !Int [(Int, [Run])] !Int        -- ^ height; (baseline offset, runs) per cell line; line count
  | VFloat !Int                          -- ^ figure index (1-based)
  | VForce
  deriving (Show)

-- | A laid-out figure block (relative to its own top, @y = 0@).
data FigBlock = FigBlock
  { fbHeight :: !Int
  , fbFrame :: Maybe (Int, Int, Int)    -- ^ x, width, height
  , fbLines :: [(Int, SetLine)]         -- ^ baseline offset, line
  } deriving (Show)

-- | Counters accumulated while lists are broken.
data Stats = Stats
  { stDemerits :: !Int
  , stHyphenated :: !Int
  , stOverfull :: !Int
  , stEmergency :: !Int
  } deriving (Show)

noStats :: Stats
noStats = Stats 0 0 0 0

addStats :: Stats -> Stats -> Stats
addStats (Stats a b c d) (Stats a' b' c' d') = Stats (a + a') (b + b') (c + c') (d + d')
