-- |
-- Module      : Text.Regex.Backtrack.Analysis
-- Description : Static facts about a pattern used to prune start positions.
module Text.Regex.Backtrack.Analysis
  ( firstChars
  , startAnchored
  ) where

import Text.Regex.Backtrack.CharSet (CharSet)
import qualified Text.Regex.Backtrack.CharSet as CS
import Text.Regex.Backtrack.Syntax

-- | @firstChars n@ is @Just s@ when every match of @n@ consumes at least one
-- character and that character always lies in @s@; it is 'Nothing' when @n@
-- can match without consuming input (so every start position, including the
-- end of the subject, must be tried).
--
-- Anchors count as consuming nothing, so they never make a pattern look
-- non-nullable; the result is therefore conservative.
firstChars :: Node -> Maybe CharSet
firstChars node = case info node of
  (s, False) -> Just s
  (_, True)  -> Nothing

-- (possible first characters, can match without consuming a character)
info :: Node -> (CharSet, Bool)
info node = case node of
  Literal c        -> (CS.singleton c, False)
  AnyChar          -> (CS.full, False)
  Class s          -> (s, False)
  StartAnchor      -> (CS.empty, True)
  EndAnchor        -> (CS.empty, True)
  Group _ n        -> info n
  Seq ns           -> seqInfo ns
  Alt ns           -> let is = map info ns
                      in (CS.unions (map fst is), any snd is)
  Repeat mn _ n    -> let (s, nl) = info n in (s, nl || mn == 0)
  where
    seqInfo [] = (CS.empty, True)
    seqInfo (n : ns) =
      let (s, nl) = info n
      in if nl then let (s', nl') = seqInfo ns in (CS.union s s', nl')
               else (s, False)

-- | True when every match must begin at position 0 (the pattern passes
-- through a @^@ before consuming anything).
startAnchored :: Node -> Bool
startAnchored node = case node of
  StartAnchor      -> True
  Group _ n        -> startAnchored n
  Seq ns           -> any startAnchored ns
  Alt ns           -> all startAnchored ns
  Repeat mn _ n    -> mn >= 1 && startAnchored n
  _                -> False
