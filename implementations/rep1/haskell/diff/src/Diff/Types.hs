-- |
-- Module      : Diff.Types
-- Description : The edit-script data type shared by the whole library.
module Diff.Types
  ( Edit (..)
  , editCost
  , scriptCost
  , isChange
  ) where

-- | One step of an edit script.
--
-- * 'Keep' x: the next unconsumed element of the old sequence, also present in
--   the new one.
-- * 'Delete' x: the next unconsumed element of the old sequence, absent from
--   the new one.
-- * 'Insert' x: an element that appears in the new sequence at this position.
data Edit a
  = Keep   !a
  | Delete !a
  | Insert !a
  deriving (Eq, Show, Read)

instance Functor Edit where
  fmap f (Keep x)   = Keep (f x)
  fmap f (Delete x) = Delete (f x)
  fmap f (Insert x) = Insert (f x)

instance Foldable Edit where
  foldr f z (Keep x)   = f x z
  foldr f z (Delete x) = f x z
  foldr f z (Insert x) = f x z

-- | Is this a 'Delete' or an 'Insert'?
isChange :: Edit a -> Bool
isChange (Keep _) = False
isChange _        = True

-- | Cost of a single step: 0 for 'Keep', 1 otherwise.
editCost :: Edit a -> Int
editCost e = if isChange e then 1 else 0

-- | Cost of a script: its number of deletions plus insertions.
scriptCost :: [Edit a] -> Int
scriptCost = length . filter isChange
