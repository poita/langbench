-- | The abstract syntax of patterns.
module Regex.Syntax
  ( Node (..)
  , groupCount
  ) where

import Data.Word (Word8)

import Regex.CharSet (CharSet)

-- | A parsed pattern.
data Node
  = Lit !Word8                 -- ^ a literal character
  | AnyChar                    -- ^ @.@
  | Set !CharSet               -- ^ a class or set escape (already resolved, negation applied)
  | Bol                        -- ^ @^@: only at position 0
  | Eol                        -- ^ @$@: only at the end of the subject
  | Seq [Node]                 -- ^ concatenation (the empty list matches the empty string)
  | Alt [Node]                 -- ^ ordered choice, tried left to right
  | Group !Int Node            -- ^ capturing group, numbered from 1
  | Repeat !Int !(Maybe Int) Node
    -- ^ greedy repetition @{min,max}@; 'Nothing' means unbounded
  deriving (Eq, Show)

-- | Number of capture groups in a tree.
groupCount :: Node -> Int
groupCount node = case node of
  Seq xs        -> sum (map groupCount xs)
  Alt xs        -> sum (map groupCount xs)
  Group _ x     -> 1 + groupCount x
  Repeat _ _ x  -> groupCount x
  _             -> 0
