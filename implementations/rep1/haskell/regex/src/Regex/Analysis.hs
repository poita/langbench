-- | Static analysis used to cut down the start positions tried by a search.
module Regex.Analysis
  ( firstChars
  , startAnchored
  ) where

import qualified Regex.CharSet as CS
import Regex.Syntax

-- | @firstChars n = (s, e)@: every non-empty match of @n@ begins with a
-- character in @s@; @e@ is 'True' when @n@ might match without consuming a
-- character (conservatively so for anchors).  If @e@ is 'False' a start
-- position whose character is not in @s@ cannot begin a match.
firstChars :: Node -> (CS.CharSet, Bool)
firstChars node = case node of
  Lit c    -> (CS.singleton c, False)
  AnyChar  -> (CS.full, False)
  Set s    -> (s, False)
  Bol      -> (CS.empty, True)
  Eol      -> (CS.empty, True)
  Group _ x -> firstChars x
  Alt xs   -> let rs = map firstChars xs
              in (CS.unions (map fst rs), any snd rs)
  Seq xs   -> goSeq xs CS.empty
  Repeat lo hi x
    | hi == Just 0 -> (CS.empty, True)
    | otherwise    -> let (s, e) = firstChars x in (s, e || lo == 0)
  where
    goSeq [] acc = (acc, True)
    goSeq (x:xs) acc =
      let (s, e) = firstChars x
          acc' = CS.union acc s
      in if e then goSeq xs acc' else (acc', False)

-- | True when every match must start at position 0 (the pattern is
-- anchored with @^@ on all paths), so only that start needs trying.
startAnchored :: Node -> Bool
startAnchored node = case node of
  Bol           -> True
  Group _ x     -> startAnchored x
  Alt xs        -> not (null xs) && all startAnchored xs
  Seq (x:xs)    -> startAnchored x || (zeroWidthOnly x && startAnchored (Seq xs))
  Repeat lo _ x -> lo >= 1 && startAnchored x
  _             -> False
  where
    -- a node that can only ever match the empty string without side effects
    -- on the position (anchors and groups/sequences made only of them)
    zeroWidthOnly n = case n of
      Bol       -> True
      Eol       -> True
      Seq xs    -> all zeroWidthOnly xs
      Group _ x -> zeroWidthOnly x
      _         -> False
