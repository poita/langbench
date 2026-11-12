-- |
-- Module      : Spiremark.Engine.Combat
-- Description : Attack and block legality, declarations and combat damage
--               (SPEC.md section 19).
module Spiremark.Engine.Combat
  ( canAttack
  , canBlock
  , attackersLegal
  , blockProvokeOk
  , inCombat
  , declareAttackers
  , declareBlockers
  , combatDamageStep
  , endCombat
  , defendingPlayer
  ) where

import Control.Monad
import Control.Monad.State.Strict
import qualified Data.IntSet as IS
import Data.List (sort, sortOn)

import Spiremark.Card.Types
import Spiremark.Engine.Core
import Spiremark.Engine.Derive
import Spiremark.Engine.Eval
import Spiremark.Engine.Target (targetKey)
import Spiremark.Engine.Types
import Spiremark.Types

defendingPlayer :: G -> Player
defendingPlayer = other . gActive

isUnit :: Obj -> Bool
isUnit o = cardType (oCard o) == Unit

-- | SPEC.md 19.2.
canAttack :: G -> View -> Int -> Bool
canAttack g v o = case lookupObj o g of
  Just ob ->
    onField ob && vCtl v o == gActive g && isUnit ob && not (fExhausted (oF ob))
      && (fSince (oF ob) < gTurn g || hasKw v o Vanguard)
      && not (hasKw v o Shackled)
  Nothing -> False

-- | SPEC.md 19.4: can blocker @b@ block attacker @a@?
canBlock :: G -> View -> Int -> Int -> Bool
canBlock g v b a = case (lookupObj b g, lookupObj a g) of
  (Just bo, Just ao) ->
    onField bo && vCtl v b == defendingPlayer g && isUnit bo
      && not (fExhausted (oF bo)) && not (hasKw v b Siegework)
      && onField ao && fAttacking (oF ao)
      && (not (hasKw v a Ghostwalk) || hasKw v b Ghostwalk || hasKw v b Skyhook)
  _ -> False

-- | Every @relentless@ unit that can attack must be in the list.
attackersLegal :: G -> View -> [Int] -> (Bool, Bool)
attackersLegal g v os = (all (canAttack g v) os, required)
  where
    required = and
      [ o `elem` os
      | o <- fieldOids g, canAttack g v o, hasKw v o Relentless ]

-- | Provoke is satisfied by a set of (blocker, attacker) pairs (SPEC.md 19.4).
blockProvokeOk :: G -> View -> [(Int, Int)] -> Bool
blockProvokeOk g v pairs = all ok attackers
  where
    attackers = [ a | a <- fieldOids g, fAttacking (oF (getObj a g)), hasKw v a Provoke ]
    usedBlockers = map fst pairs
    blockedAttackers = map snd pairs
    defenders = [ b | b <- fieldOids g, vCtl v b == defendingPlayer g ]
    ok a = a `elem` blockedAttackers
      || not (any (\b -> b `notElem` usedBlockers && canBlock g v b a) defenders)

-- | On the Field and attacking or blocking.
inCombat :: Obj -> Bool
inCombat ob = onField ob && (fAttacking (oF ob) || fBlocking (oF ob) /= Nothing)

-- | Apply a legal @ATTACK@ (SPEC.md 19.1), excluding the priority round.
declareAttackers :: [Int] -> Eng ()
declareAttackers os = do
  let sorted = sort os
  forM_ sorted $ \o -> do
    updField o (\f -> f { fAttacking = True })
    v <- getView
    unless (hasKw v o Vigil) $ setExhausted o
    emit ("ATTACK #" ++ show o)
  forM_ sorted $ \o -> collectOne EvAttacks o (SubObj o)
  mutQ (\g -> g { gDealt = IS.empty })

-- | Apply a legal @BLOCK@ (SPEC.md 19.3), excluding the priority round.
declareBlockers :: [(Int, Int)] -> Eng ()
declareBlockers pairs = do
  let sorted = sortOn fst pairs
  forM_ sorted $ \(b, a) -> do
    updField b (\f -> f { fBlocking = Just a })
    g <- get
    let bts = (oTs (getObj b g), b)
        key x = (oTs (getObj x g), x)
        ins xs = let (lo, hi) = span (\x -> key x < bts) xs in lo ++ [b] ++ hi
    updField a (\f -> f { fBlockers = ins (fBlockers f), fBlocked = True })
    emit ("BLOCK #" ++ show b ++ " #" ++ show a)
  g <- get
  let attackers = [ a | a <- fieldOids g, fAttacking (oF (getObj a g)) ]
      unblocked = sort [ a | a <- attackers, null (fBlockers (oF (getObj a g))) ]
  forM_ unblocked $ \a -> emit ("UNBLOCKED #" ++ show a)
  forM_ sorted $ \(b, a) -> collectOne EvBlocks b (SubObj a)
  forM_ (sort attackers) $ \a -> do
    g' <- get
    case fBlockers (oF (getObj a g')) of
      (b : _) -> collectOne EvBlocked a (SubObj b)
      [] -> return ()
  forM_ unblocked $ \a -> collectOne EvUnblocked a (SubObj a)

-- | Deal the combat damage of the given units (SPEC.md 19.6, 17.2).
dealCombat :: [Int] -> Eng ()
dealCombat us = do
  g <- get
  v <- getView
  let defender = defendingPlayer g
      assign u =
        let ob = getObj u g
            fs = oF ob
            e = vEdge v u
         in if e <= 0 then [] else case () of
              _ | Just a <- fBlocking fs ->
                    [ (u, TgtObj a, e) | maybe False onField (lookupObj a g) ]
                | fAttacking fs && not (fBlocked fs) -> [(u, TgtPlayer defender, e)]
                | fAttacking fs ->
                    let ls = [ b | b <- fBlockers fs
                                 , Just bo <- [lookupObj b g]
                                 , onField bo, fBlocking (oF bo) == Just u ]
                     in if null ls then [] else walk u e ls
                | otherwise -> []
      walk u e ls =
        let venom = hasKw v u Venom
            need b = if venom then 1 else max 0 (vCore v b - fWounds (oF (getObj b g)))
            step (r, acc) b = let x = min r (need b) in (r - x, acc ++ [(b, x)])
            (rest, given) = foldl step (e, []) ls
            lastB = last ls
            given' | rest > 0 && not (hasKw v u Pierce) =
                       [ (b, if b == lastB then x + rest else x) | (b, x) <- given ]
                   | otherwise = given
            toPlayer = [ (u, TgtPlayer defender, rest) | rest > 0 && hasKw v u Pierce ]
         in [ (u, TgtObj b, x) | (b, x) <- given' ] ++ toPlayer
      triples = [ t | (t@(_, _, n)) <- concatMap assign us, n > 0 ]
      sorted = sortOn (\(s, t, _) -> (targetKey g (TgtObj s), targetKey g t)) triples
  forM_ sorted $ \(s, t, n) -> dealDamage s t n

-- | The riposte sub-step when @riposte=True@ (units in combat with @riposte@),
-- else the ordinary damage step (units in combat that have not yet dealt).
combatDamageStep :: Bool -> Eng ()
combatDamageStep riposte = do
  g <- get
  v <- getView
  let inC = [ o | o <- fieldOids g, inCombat (getObj o g), isUnit (getObj o g) ]
  if riposte
    then do
      let us = [ o | o <- inC, hasKw v o Riposte ]
      mutQ (\s -> s { gDealt = IS.fromList us })
      dealCombat us
    else do
      let us = [ o | o <- inC, not (IS.member o (gDealt g)) ]
      dealCombat us

-- | Clear all combat status (end of the clash-end step).
endCombat :: Eng ()
endCombat = do
  g <- get
  forM_ (fieldOids g) $ \o ->
    let f = oF (getObj o g)
     in when (fAttacking f || fBlocking f /= Nothing || fBlocked f || not (null (fBlockers f))) $
          updField o (\x -> x { fAttacking = False, fBlocking = Nothing, fBlocked = False, fBlockers = [] })
  mutQ (\s -> s { gDealt = IS.empty })
