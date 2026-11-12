-- |
-- Module      : Diff
-- Description : Minimal diffs and patches of sequences.
--
-- > import Diff
-- >
-- > let script = diff "abcabba" "cbabac"
-- > scriptCost script        -- 5, the minimum
-- > patch "abcabba" script   -- Right "cbabac"
--
-- 'diff' computes a /shortest/ edit script with Myers' algorithm
-- ("Diff.Myers"); 'patch' ("Diff.Patch") replays a script.  The textual script
-- format used by the command-line tool lives in "Diff.Script" and the
-- stdin/stdout protocol in "Diff.Protocol".
module Diff
  ( -- * Diffing
    diff
  , diffBy
    -- * Patching
  , patch
  , PatchError (..)
    -- * Edit scripts
  , Edit (..)
  , scriptCost
    -- * Low level
  , diffIds
  ) where

import           Data.Array         (Array, listArray, (!))

import           Diff.Intern        (internPair)
import           Diff.Myers         (diffIds)
import           Diff.Patch
import           Diff.Types

-- | A shortest edit script turning the first sequence into the second.  The
-- 'Keep' and 'Delete' steps carry elements of the first sequence, the 'Insert'
-- steps elements of the second.
--
-- Time O((N+M)·D) where D = 'scriptCost' of the result, space O(N+M).
diff :: Ord a => [a] -> [a] -> [Edit a]
diff = diffBy id

-- | 'diff' where equality is taken after projecting elements through a key.
-- Elements in the script are the original ones; a 'Keep' carries the element
-- of the first sequence.
diffBy :: Ord k => (a -> k) -> [a] -> [a] -> [Edit a]
diffBy key xs ys = map resolve (diffIds ia ib)
  where
    (ia, ib) = internPair (map key xs) (map key ys)
    xa = toArray xs
    ya = toArray ys
    resolve (Keep i)   = Keep (xa ! i)
    resolve (Delete i) = Delete (xa ! i)
    resolve (Insert j) = Insert (ya ! j)

toArray :: [a] -> Array Int a
toArray zs = listArray (0, length zs - 1) zs
