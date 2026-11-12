-- |
-- Module      : Text.Regex.Backtrack.Syntax
-- Description : The abstract syntax tree of a pattern.
module Text.Regex.Backtrack.Syntax
  ( Node (..)
  , Pattern (..)
  ) where

import Text.Regex.Backtrack.CharSet (CharSet)

-- | A node of the pattern syntax tree.
data Node
  = Literal !Char
    -- ^ A single literal character.
  | AnyChar
    -- ^ @.@ — any single character.
  | Class !CharSet
    -- ^ A character class (or class escape such as @\\d@), already resolved
    -- to a set (negation is applied at parse time).
  | StartAnchor
    -- ^ @^@ — succeeds only at position 0.
  | EndAnchor
    -- ^ @$@ — succeeds only at the end of the subject.
  | Seq [Node]
    -- ^ Concatenation; @Seq []@ is the empty pattern.
  | Alt [Node]
    -- ^ Ordered alternation (at least one branch).
  | Group !Int Node
    -- ^ Capturing group with its 1-based number.
  | Repeat !Int !(Maybe Int) Node
    -- ^ @Repeat min max node@: greedy repetition; 'Nothing' is unbounded.
  deriving (Eq, Show)

-- | A parsed pattern: its tree and number of capture groups.
data Pattern = Pattern
  { patternNode   :: Node
  , patternGroups :: !Int
  } deriving (Eq, Show)
