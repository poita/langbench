-- |
-- Module      : Spiremark.Engine.Report
-- Description : Inspection blocks: @DUMP@, @LEGAL@, @VAULT@ (SPEC.md 21, 23).
module Spiremark.Engine.Report
  ( dumpBlock
  , legalBlock
  , vaultBlock
  , decisionLine
  ) where

import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.Foldable (toList)
import Data.List (intercalate, sort, sortOn)
import Data.Maybe (fromMaybe)
import qualified Data.Sequence as Seq

import Spiremark.Card.Types
import Spiremark.Engine.Chain
import Spiremark.Engine.Combat
import Spiremark.Engine.Derive
import Spiremark.Engine.Eval
import Spiremark.Engine.Target
import Spiremark.Engine.Types
import Spiremark.Types

derivedOf :: G -> Derived
derivedOf g = fromMaybe (derive g) (gDerived g)

kindName :: Decision -> String
kindName DPriority = "priority"
kindName DAttackers = "attackers"
kindName DBlockers = "blockers"

-- | The waiting player and decision kind, if the match is running.
decisionLine :: G -> Maybe (Player, Decision)
decisionLine g = case gMode g of
  MAwait DPriority -> Just (gHolder g, DPriority)
  MAwait DAttackers -> Just (gActive g, DAttackers)
  MAwait DBlockers -> Just (other (gActive g), DBlockers)
  _ -> Nothing

commaOrDash :: [String] -> String
commaOrDash [] = "-"
commaOrDash xs = intercalate "," xs

-- | The @DUMP@ block (SPEC.md 23.1).
dumpBlock :: G -> [String]
dumpBlock g =
  ["STATE BEGIN", turnLine]
    ++ [ "result " ++ w ++ " " ++ r | Just (w, r) <- [gResult g] ]
    ++ [playerLine A, playerLine B]
    ++ concat [ handLines p | p <- [A, B] ]
    ++ concat [ fieldLines p | p <- [A, B] ]
    ++ concat [ zoneLines "ash" pAsh p | p <- [A, B] ]
    ++ concat [ zoneLines "rift" pRift p | p <- [A, B] ]
    ++ chainLines
    ++ effectLines
    ++ delayedLines
    ++ ["STATE END"]
  where
    d = derivedOf g
    v = viewOf g d
    turnLine = "turn " ++ show (gTurn g) ++ " active " ++ playerName (gActive g)
      ++ " phase " ++ phaseName (gPhase g) ++ " decision " ++ case decisionLine g of
          Just (p, k) -> playerName p ++ " " ++ kindName k
          Nothing -> "- over"
    playerLine p =
      let ps = pst p g
       in "player " ++ playerName p ++ " spire " ++ show (pSpire ps) ++ " ember " ++ show (pEmber ps)
            ++ " cap " ++ show (pCap ps) ++ " vault " ++ show (Seq.length (pVault ps))
            ++ " hand " ++ show (Seq.length (pHand ps)) ++ " ash " ++ show (Seq.length (pAsh ps))
            ++ " rift " ++ show (Seq.length (pRift ps))
    handLines = zoneLines "hand" pHand
    zoneLines name f p =
      [ name ++ " " ++ playerName p ++ " " ++ show i ++ " #" ++ show o ++ " " ++ cardId (oCard (getObj o g))
      | (i, o) <- zip [1 :: Int ..] (toList (f (pst p g))) ]
    fieldLines p =
      [ fieldLine o | o <- fieldOids g, vCtl v o == p ]
    fieldLine o =
      let ob = getObj o g
          fs = oF ob
          stats = case cardType (oCard ob) of
            Relic -> "-/-"
            _ -> let (e, c) = IM.findWithDefault (0, 0) o (dStats d) in show e ++ "/" ++ show c
          flags = sort $
            [ "attacking" | fAttacking fs ] ++ [ "blocked" | fBlocked fs ]
            ++ [ "blocking" | fBlocking fs /= Nothing ] ++ [ "doomed" | fDoomed fs ]
            ++ [ "once" ++ show i | i <- IS.toList (fOnce fs) ]
            ++ [ "settling" | fSince fs >= gTurn g ] ++ [ "tenacity-used" | fTenUsed fs ]
            ++ [ "ward" ++ show (fWard fs) | fWard fs > 0 ]
          kws = sort (kwList (vKw v o))
       in "field " ++ playerName (vCtl v o) ++ " #" ++ show o ++ " " ++ cardId (oCard ob) ++ " " ++ stats
            ++ " w" ++ show (fWounds fs) ++ " c" ++ show (fCounters fs) ++ " "
            ++ (if fExhausted fs then "exhausted" else "ready") ++ " " ++ commaOrDash flags
            ++ " kw " ++ commaOrDash kws
    kwList ks =
      [ renderKw (KwSpec k 0) | k <- allKeywords, k /= Plating, any (\(KwSpec k' _) -> k' == k) ks ]
      ++ [ "plating:" ++ show (sum [n | KwSpec Plating n <- ks]) | any (\(KwSpec k' _) -> k' == Plating) ks ]
    chainLines =
      [ "chain " ++ show i ++ " ~" ++ show (enCid e) ++ " " ++ playerName (enCtl e) ++ " "
          ++ ekind (enKind e) ++ " #" ++ show (enSrc e) ++ " " ++ show (enIdx e)
          ++ concatMap (\s -> ' ' : slotStr s) (enSlots e)
      | (i, e) <- zip [1 :: Int ..] (reverse (gChain g)) ]
    ekind k = case k of
      EKRite -> "rite"; EKUnit -> "unit"; EKRelic -> "relic"
      EKAbility -> "ability"; EKTrigger -> "trigger"
    slotStr s = if slRemoved s then "-" else renderTarget (slTarget s)
    effectLines = [ effectLine r | r <- sortOn rEid (IM.elems (gRecs g)) ]
    effectLine r = case rBody r of
      RDiscrete k objs ->
        let live = [ o | o <- objs, maybe False onField (lookupObj o g) ]
         in "effect " ++ show (rEid r) ++ " ts" ++ show (rTs r) ++ " " ++ playerName (rCtl r)
              ++ " turn " ++ dkind k ++ " on " ++ objList live
      RAura _ -> case IM.lookup (rEid r) (dAuras d) of
        Just ae -> "effect " ++ show (rEid r) ++ " ts" ++ show (rTs r) ++ " " ++ playerName (aeCtl ae)
                     ++ " aura " ++ aeDesc ae ++ " on " ++ objList (aeObjs ae)
        Nothing -> "effect " ++ show (rEid r) ++ " ts" ++ show (rTs r) ++ " A aura - on -"
    objList [] = "-"
    objList os = intercalate "," (map (\o -> '#' : show o) os)
    dkind k = case k of
      DModify e c -> "modify " ++ show e ++ " " ++ show c
      DSetbody e c -> "setbody " ++ show e ++ " " ++ show c
      DSwap -> "swapstats"
      DGrant s -> "grant " ++ renderKw s
      DStrip -> "strip"
      DControl p -> "control " ++ playerName p
    delayedLines =
      [ "delayed " ++ show (dlTs dl) ++ " " ++ playerName (dlCtl dl) ++ " " ++ whenName (dlWhen dl)
          ++ concatMap (\s -> ' ' : slotStr s) (dlSlots dl)
      | dl <- sortOn dlTs (gDelayed g) ]

-- | The @VAULT@ block (SPEC.md 23.3).
vaultBlock :: G -> [String]
vaultBlock g =
  ["VAULT BEGIN"]
    ++ [ "vault " ++ playerName p ++ " " ++ show i ++ " #" ++ show o ++ " " ++ cardId (oCard (getObj o g))
       | p <- [A, B], (i, o) <- zip [1 :: Int ..] (toList (pVault (pst p g))) ]
    ++ ["VAULT END"]

-- | The @LEGAL@ block (SPEC.md 21, 23.2).
legalBlock :: G -> [String]
legalBlock g = case decisionLine g of
  Nothing -> ["LEGAL BEGIN - over", "LEGAL END"]
  Just (p, k) ->
    ["LEGAL BEGIN " ++ playerName p ++ " " ++ kindName k] ++ body p k ++ ["LEGAL END"]
  where
    d = derivedOf g
    v = viewOf g d
    body p DPriority = "PASS" : plays p ++ acts p
    body _ DAttackers =
      let cans = [ o | o <- fieldOids g, canAttack g v o ]
          cans' = sort cans
       in [ "CANATTACK #" ++ show o | o <- cans' ]
            ++ [ "MUSTATTACK #" ++ show o | o <- cans', hasKw v o Relentless ]
    body _ DBlockers =
      let attackers = sort [ a | a <- fieldOids g, fAttacking (oF (getObj a g)) ]
          blockers = sort [ b | b <- fieldOids g, vCtl v b == defendingPlayer g ]
       in [ "CANBLOCK #" ++ show b ++ " #" ++ show a
          | b <- blockers, a <- attackers, canBlock g v b a ]
            ++ [ "MUSTBLOCK #" ++ show a | a <- attackers, hasKw v a Provoke ]
    plays p =
      [ "PLAY " ++ show i ++ " " ++ cardId card ++ concatMap (\t -> ' ' : renderTarget t) ts
      | (i, o) <- zip [1 :: Int ..] (toList (pHand (pst p g)))
      , let card = oCard (getObj o g)
      , playTimingOk g p card
      , playCost d p card <= pEmber (pst p g)
      , ts <- tuples [ candidates g v p o Nothing s | s <- playSpecs card ]
      ]
    acts p =
      [ "ACT #" ++ show o ++ " " ++ show (abIndex ab) ++ concatMap (\t -> ' ' : renderTarget t) ts
      | o <- sort (fieldOids g)
      , let ob = getObj o g
      , vCtl v o == p
      , not (isStripped d o)
      , ab <- cardAbilities (oCard ob)
      , abKind ab == AKAct
      , costsPayable g v p ob (abIndex ab) (abCost ab)
      , ts <- tuples [ candidates g v p o Nothing s | s <- abTargets ab ]
      ]
