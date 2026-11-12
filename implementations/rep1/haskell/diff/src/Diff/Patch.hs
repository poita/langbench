-- |
-- Module      : Diff.Patch
-- Description : Apply an edit script to a sequence.
module Diff.Patch
  ( PatchError (..)
  , patch
  , patchUnchecked
  ) where

import Diff.Types

-- | Why a script could not be applied.
data PatchError
  = ScriptEndsEarly
    -- ^ A 'Keep' or 'Delete' step found no remaining element to consume.
  | ElementMismatch
    -- ^ A 'Keep' or 'Delete' step named an element different from the one in
    --   the sequence being patched.
  | ElementsLeftOver
    -- ^ The script finished before consuming the whole sequence.
  deriving (Eq, Show)

-- | Apply a script to a sequence in a single pass, checking that the script's
-- 'Keep' and 'Delete' elements are exactly the sequence.  O(N + K).
--
-- @patch xs (diff xs ys) == Right ys@
patch :: Eq a => [a] -> [Edit a] -> Either PatchError [a]
patch = go
  where
    go []       []             = Right []
    go _        []             = Left ElementsLeftOver
    go src      (Insert y : es) = (y :) <$> go src es
    go []       (_ : _)        = Left ScriptEndsEarly
    go (x : xs) (Keep y : es)
      | x == y    = (x :) <$> go xs es
      | otherwise = Left ElementMismatch
    go (x : xs) (Delete y : es)
      | x == y    = go xs es
      | otherwise = Left ElementMismatch

-- | Like 'patch' but trusts the script: 'Keep' and 'Delete' consume an element
-- of the sequence without comparing it.  Missing elements are ignored.
patchUnchecked :: [a] -> [Edit a] -> [a]
patchUnchecked _        []             = []
patchUnchecked src      (Insert y : es) = y : patchUnchecked src es
patchUnchecked (x : xs) (Keep _ : es)   = x : patchUnchecked xs es
patchUnchecked (_ : xs) (Delete _ : es) = patchUnchecked xs es
patchUnchecked []       (_ : es)        = patchUnchecked [] es
