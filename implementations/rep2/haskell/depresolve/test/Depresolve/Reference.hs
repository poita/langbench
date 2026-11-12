-- | A deliberately naive transcription of the recursion in SPEC.md, using
-- plain lists and maps.  It is the oracle for the property tests.
module Depresolve.Reference (referenceResolve) where

import Data.List (sortBy)
import qualified Data.Map as M
import Data.Ord (Down (..), comparing)

import Depresolve

referenceResolve :: Problem -> Maybe [(Name, Version)]
referenceResolve (Problem registry root) = fmap M.toAscList (go root M.empty)
  where
    go [] chosen = Just chosen
    go (Requirement n r : rest) chosen = case M.lookup n chosen of
      Just v | satisfies r v -> go rest chosen
             | otherwise -> Nothing
      Nothing -> firstJust
        [ go (pvRequirements pv ++ rest) (M.insert n (pvVersion pv) chosen)
        | pv <- candidates n r ]
    candidates n r =
      sortBy (comparing (Down . pvVersion))
        [pv | pv <- registry, pvName pv == n, satisfies r (pvVersion pv)]
    firstJust [] = Nothing
    firstJust (Just x : _) = Just x
    firstJust (Nothing : xs) = firstJust xs
