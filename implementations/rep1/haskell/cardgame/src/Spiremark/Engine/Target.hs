-- |
-- Module      : Spiremark.Engine.Target
-- Description : Target legality, candidate enumeration and ordering (SPEC.md 12).
module Spiremark.Engine.Target
  ( legalTarget
  , candidates
  , targetKey
  , tuples
  , autoTargets
  , mkEnvFor
  ) where

import Data.List (sortOn)
import qualified Data.Set as Set

import Spiremark.Card.Types
import Spiremark.Engine.Derive
import Spiremark.Engine.Eval
import Spiremark.Engine.Types
import Spiremark.Types

-- | An evaluation environment relative to an ability controller and source.
mkEnvFor :: G -> View -> Player -> Int -> Env
mkEnvFor g v c src = Env g v (Ctx c src Nothing Nothing [] []) True

-- | The sort key of a target (SPEC.md 12.4).
targetKey :: G -> Target -> (Int, Int, Int)
targetKey _ (TgtPlayer A) = (0, 0, 0)
targetKey _ (TgtPlayer B) = (0, 1, 0)
targetKey g (TgtObj o) = (1, maybe 0 oTs (lookupObj o g), o)
targetKey _ (TgtEntry c) = (2, c, 0)

-- | Whether an object is a legal target for a unit/relic/any spec of an ability
-- controlled by @c@: the spectral rule applies to units on the Field.
objLegal :: Env -> View -> Player -> CardType -> [Filter] -> Int -> Bool
objLegal env v c ty fs o = case lookupObj o (enG env) of
  Just ob ->
    onField ob
      && cardType (oCard ob) == ty
      && matchFilters env ob fs
      && not (ty == Unit && hasKw v o Spectral && vCtl v o /= c)
  Nothing -> False

-- | Is the target legal for the spec?  @excl@ is the cid of the entry being
-- announced or resolved (a @chained@ target may not be it).
legalTarget :: G -> View -> Player -> Int -> Maybe Int -> TSpec -> Target -> Bool
legalTarget g v c src excl spec t = case (spec, t) of
  (TUnit fs, TgtObj o) -> objLegal env v c Unit fs o
  (TRelic fs, TgtObj o) -> objLegal env v c Relic fs o
  (TAny _, TgtPlayer _) -> True
  (TAny fs, TgtObj o) -> objLegal env v c Unit fs o
  (TPlayer, TgtPlayer _) -> True
  (TChained, TgtEntry cid) ->
    Just cid /= excl && any ((== cid) . enCid) (gChain g)
  (TAshCard fs, TgtObj o) -> case lookupObj o g of
    Just ob -> oZone ob == ZnAsh && matchFilters env ob fs
    Nothing -> False
  _ -> False
  where env = mkEnvFor g v c src

-- | All legal targets for a spec, in ascending target-key order.
candidates :: G -> View -> Player -> Int -> Maybe Int -> TSpec -> [Target]
candidates g v c src excl spec = case spec of
  TUnit fs -> units fs
  TRelic fs -> [TgtObj o | o <- fieldOids g, objLegal env v c Relic fs o]
  TAny fs -> [TgtPlayer A, TgtPlayer B] ++ units fs
  TPlayer -> [TgtPlayer A, TgtPlayer B]
  TChained -> [TgtEntry (enCid e) | e <- sortOn enCid (gChain g), Just (enCid e) /= excl]
  TAshCard fs ->
    let ashes = [o | p <- [A, B], o <- toL (pAsh (pst p g))]
        toL = foldr (:) []
        ok o = matchFilters env (getObj o g) fs
     in map TgtObj (map snd (Set.toAscList (Set.fromList [(oTs (getObj o g), o) | o <- ashes, ok o])))
  where
    env = mkEnvFor g v c src
    units fs = [TgtObj o | o <- fieldOids g, objLegal env v c Unit fs o]

-- | All tuples of pairwise-distinct legal targets, lexicographically ordered.
tuples :: [[Target]] -> [[Target]]
tuples = go []
  where
    go _ [] = [[]]
    go chosen (cs : rest) =
      [ t : more
      | t <- cs
      , t `notElem` chosen
      , more <- go (t : chosen) rest
      ]

-- | Automatic target choice for triggers (SPEC.md 13.4): the first legal
-- candidate distinct from those already chosen, per spec.
autoTargets :: G -> View -> Player -> Int -> [TSpec] -> Maybe [Target]
autoTargets g v c src = go []
  where
    go acc [] = Just (reverse acc)
    go acc (s : ss) =
      case [t | t <- candidates g v c src Nothing s, t `notElem` acc] of
        (t : _) -> go (t : acc) ss
        [] -> Nothing
