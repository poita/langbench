-- | A direct transcription of the specification's recursive search, used as
-- an oracle for the optimised implementation.
module Reference (referenceResolve) where

import Data.List (sortBy)
import qualified Data.Map as M
import Data.Ord (comparing, Down (..))

import Depresolve

referenceResolve :: Registry -> [Requirement] -> Maybe [(PackageName, Version)]
referenceResolve reg root = fmap M.toAscList (go root M.empty)
  where
    go [] chosen = Just chosen
    go (Requirement n r : rest) chosen = case M.lookup n chosen of
      Just v -> if satisfies r v then go rest chosen else Nothing
      Nothing ->
        let cands = sortBy (comparing (Down . fst))
                      [(v, rs) | (v, rs) <- versionsOf n reg, satisfies r v]
            try [] = Nothing
            try ((v, rs) : more) = case go (rs ++ rest) (M.insert n v chosen) of
              Nothing -> try more
              res -> res
         in try cands
