-- |
-- Module      : Spiremark.Engine.Chain
-- Description : The Chain: playing, activating, triggering, resolving, settling.
--
-- Implements SPEC.md sections 10 (settle, drain), 11 (plays and activations),
-- 12 (target checks on announcement and resolution) and 13.3 (pushing
-- triggers).
module Spiremark.Engine.Chain
  ( settle
  , drain
  , pushTriggers
  , resolveTop
  , playCard
  , activateAbility
  , playTimingOk
  , playCost
  , costsPayable
  , playSpecs
  , actAbility
  ) where

import Control.Monad
import Control.Monad.State.Strict
import qualified Data.IntSet as IS
import Data.List (sortOn)
import Data.Maybe (catMaybes)
import qualified Data.Sequence as Seq
import Data.Foldable (toList)

import Spiremark.Card.Types
import Spiremark.Engine.Core
import Spiremark.Engine.Derive
import Spiremark.Engine.Effects
import Spiremark.Engine.Eval
import Spiremark.Engine.Target
import Spiremark.Engine.Types
import Spiremark.Types

-- | SPEC.md 10.5.  Returns whether it did anything.  May end the match.
settle :: Eng Bool
settle = loop False
  where
    loop acted = do
      a <- stateChecks
      over <- gets isOver
      if over
        then return True
        else do
          b <- pushTriggers
          if a || b then loop True else return acted

-- | SPEC.md 10.6: settle and resolve until the Chain is empty or the match ends.
drain :: Eng ()
drain = do
  _ <- settle
  over <- gets isOver
  ch <- gets gChain
  unless (over || null ch) $ do
    resolveTop
    drain

-- | Push the collected triggers onto the Chain (SPEC.md 13.3).
pushTriggers :: Eng Bool
pushTriggers = do
  pend <- gets (reverse . gPending)
  if null pend
    then return False
    else do
      mutQ (\g -> g { gPending = [] })
      active <- gets gActive
      let key p = ( if pdCtl p == active then 0 else 1 :: Int, pdTs p, pdOid p, pdIdx p )
          sorted = sortOn key pend
      entries <- forM sorted $ \p -> case pdDelayed p of
        Just dl -> do
          cid <- freshCid
          emit ("TRIGGER " ++ playerName (dlCtl dl) ++ " ~" ++ show cid ++ " #" ++ show (dlSrc dl) ++ " 0"
                ++ renderSlots (dlSlots dl))
          return (Just Entry { enCid = cid, enKind = EKTrigger, enCtl = dlCtl dl, enSrc = dlSrc dl
                             , enIdx = 0, enSlots = dlSlots dl, enSpecs = dlSpecs dl
                             , enIt = Nothing, enEffects = Just (dlEffects dl) })
        Nothing -> do
          g <- get
          v <- getView
          let ob = getObj (pdOid p) g
              ab = cardAbilities (oCard ob) !! (pdIdx p - 1)
              specs = abTargets ab
          case autoTargets g v (pdCtl p) (pdOid p) specs of
            Nothing -> do
              emit ("TRIGGER-NO-TARGET " ++ playerName (pdCtl p) ++ " #" ++ show (pdOid p) ++ " " ++ show (pdIdx p))
              return Nothing
            Just ts -> do
              cid <- freshCid
              emit ("TRIGGER " ++ playerName (pdCtl p) ++ " ~" ++ show cid ++ " #" ++ show (pdOid p)
                    ++ " " ++ show (pdIdx p) ++ renderSlots [Slot t False | t <- ts])
              return (Just Entry { enCid = cid, enKind = EKTrigger, enCtl = pdCtl p, enSrc = pdOid p
                                 , enIdx = pdIdx p, enSlots = [Slot t False | t <- ts]
                                 , enSpecs = specs, enIt = pdIt p, enEffects = Nothing })
      mutQ (\g -> g { gChain = catMaybes entries ++ gChain g })
      return True

renderSlots :: [Slot] -> String
renderSlots = concatMap (\s -> ' ' : renderTarget (slTarget s))

freshCid :: Eng Int
freshCid = do
  c <- gets gNextCid
  mutQ (\g -> g { gNextCid = c + 1 })
  return c

-- | Resolve the top Chain entry (SPEC.md 11.6).
resolveTop :: Eng ()
resolveTop = do
  ch <- gets gChain
  case ch of
    [] -> return ()
    (e0 : _) -> do
      emit ("RESOLVE ~" ++ show (enCid e0))
      g <- get
      v <- getView
      let slots' = [ Slot t (not (legalTarget g v (enCtl e0) (enSrc e0) (Just (enCid e0)) spec t))
                   | (Slot t _, spec) <- zip (enSlots e0) (enSpecs e0) ]
          e = e0 { enSlots = slots' }
          fizzled = not (null slots') && all slRemoved slots'
          cx = Ctx { cxCtl = enCtl e, cxSrc = enSrc e, cxIt = enIt e, cxThat = Nothing
                   , cxSlots = slots', cxSpecs = enSpecs e }
      mutQ (\s -> s { gChain = map (\x -> if enCid x == enCid e then e else x) (gChain s) })
      if fizzled
        then emit ("FIZZLE ~" ++ show (enCid e))
        else case enKind e of
          EKRite -> execEffects cx (abilityEffects g (enSrc e) 1)
          EKUnit -> enterField (enSrc e) (enCtl e)
          EKRelic -> enterField (enSrc e) (enCtl e)
          _ -> case enEffects e of
            Just es -> execEffects cx es
            Nothing -> execEffects cx (abilityEffects g (enSrc e) (enIdx e))
      mutQ (\s -> s { gChain = filter ((/= enCid e) . enCid) (gChain s) })
      case enKind e of
        EKRite -> spend (enSrc e)
        k | fizzled && k `elem` [EKUnit, EKRelic] -> do
              moveTo (enSrc e) ZnAsh
        _ -> return ()
  where
    spend oid = do
      moveTo oid ZnAsh
      ob <- objIs oid
      emit ("SPENT #" ++ show oid ++ " " ++ cardId (oCard ob))

abilityEffects :: G -> Int -> Int -> [Effect]
abilityEffects g oid idx =
  case drop (idx - 1) (cardAbilities (oCard (getObj oid g))) of
    (ab : _) | idx >= 1 -> abEffects ab
    _ -> []

-- | Target specs of the @resolve@ ability of a card (rites), else none.
playSpecs :: Card -> [TSpec]
playSpecs c = case [ab | ab <- cardAbilities c, abKind ab == AKResolve] of
  (ab : _) -> abTargets ab
  [] -> []

-- | Whether a card may be played now by the holder (SPEC.md 11.1).
playTimingOk :: G -> Player -> Card -> Bool
playTimingOk g p c
  | cardType c == Rite && any ((== Swift) . kwOf) (cardKeywords c) = True
  | otherwise = p == gActive g && gPhase g `elem` [PhMain1, PhMain2] && null (gChain g)
  where kwOf (KwSpec k _) = k

-- | Ember cost after @cheaper@ reductions (SPEC.md 11.2 step 4).
playCost :: Derived -> Player -> Card -> Int
playCost d p c = max 0 (cardCost c - sum [n | (q, n, fs) <- dCheaper d, q == p, all (cfMatch c) fs])
  where
    cfMatch card f = case f of
      CFType t -> cardType card == t
      CFTag t -> t `elem` cardTags card
      CFCost cm n -> compareBy cm (cardCost card) n

-- | The activated ability with this number, if it exists on the card.
actAbility :: Card -> Int -> Maybe Ability
actAbility c i = case drop (i - 1) (cardAbilities c) of
  (ab : _) | i >= 1, abKind ab == AKAct -> Just ab
  _ -> Nothing

-- | Whether every cost item can be paid by the controller (SPEC.md 11.3 step 4).
costsPayable :: G -> View -> Player -> Obj -> Int -> [CostItem] -> Bool
costsPayable g v p ob idx = all ok
  where
    oid = oOid ob
    fs = oF ob
    ok item = case item of
      CIEmber n -> pEmber (pst p g) >= n
      CISpire _ -> True
      CIDiscard n -> Seq.length (pHand (pst p g)) >= n
      CIExhaust -> onField ob && not (fExhausted fs)
                   && (fSince fs < gTurn g || hasKw v oid Vanguard)
      CISacSelf -> onField ob
      CICounters n -> fCounters fs >= n
      CIOnce -> not (IS.member idx (fOnce fs))

type Check = Either String

-- | Play the card at a 1-based hand position (SPEC.md 11.2).  Left carries the
-- error kind; nothing is changed in that case.
playCard :: Player -> Int -> [Target] -> Eng (Check ())
playCard p pos tgts = do
  g <- get
  v <- getView
  d <- getDerived
  let hand = toList (pHand (pst p g))
  if pos < 1 || pos > length hand
    then return (Left "no-such-card")
    else do
      let oid = hand !! (pos - 1)
          ob = getObj oid g
          card = oCard ob
          specs = playSpecs card
      if not (playTimingOk g p card)
        then return (Left "bad-timing")
        else if length tgts /= length specs
          then return (Left "bad-target-count")
          else if not (targetsOk g v p oid specs tgts)
            then return (Left "illegal-target")
            else do
              let cost = playCost d p card
              if pEmber (pst p g) < cost
                then return (Left "cannot-afford")
                else do
                  cid <- freshCid
                  removeFromZone oid
                  updObjZ oid (\o -> o { oZone = ZnChain })
                  let kind = case cardType card of
                        Rite -> EKRite
                        Unit -> EKUnit
                        Relic -> EKRelic
                      entry = Entry { enCid = cid, enKind = kind, enCtl = p, enSrc = oid, enIdx = 0
                                    , enSlots = [Slot t False | t <- tgts], enSpecs = specs
                                    , enIt = Nothing, enEffects = Nothing }
                  mutQ (\s -> s { gChain = entry : gChain s })
                  emit ("PLAY " ++ playerName p ++ " ~" ++ show cid ++ " #" ++ show oid ++ " "
                        ++ cardId card ++ renderSlots (enSlots entry))
                  mutDep depPlayer (modP p (\ps -> ps { pEmber = pEmber ps - cost }))
                  when (cost > 0) $ emit ("PAY " ++ playerName p ++ " ember " ++ show cost)
                  when (cardType card == Rite) $ do
                    collectScan EvYouPlayRite (SubObj oid) (\_ c -> c == p)
                    collectScan EvEnemyPlaysRite (SubObj oid) (\_ c -> c /= p)
                  return (Right ())

-- | Distinctness plus per-spec legality.
targetsOk :: G -> View -> Player -> Int -> [TSpec] -> [Target] -> Bool
targetsOk g v p src specs tgts =
  distinct tgts && and (zipWith (legalTarget g v p src Nothing) specs tgts)
  where
    distinct [] = True
    distinct (t : ts) = t `notElem` ts && distinct ts

-- | Activate an ability (SPEC.md 11.3).
activateAbility :: Player -> Int -> Int -> [Target] -> Eng (Check ())
activateAbility p oid idx tgts = do
  g <- get
  v <- getView
  d <- getDerived
  case lookupObj oid g of
    Just ob | onField ob, vCtl v oid == p ->
      case (if isStripped d oid then Nothing else actAbility (oCard ob) idx) of
        Nothing -> return (Left "no-such-ability")
        Just ab -> do
          let specs = abTargets ab
          if length tgts /= length specs
            then return (Left "bad-target-count")
            else if not (targetsOk g v p oid specs tgts)
              then return (Left "illegal-target")
              else if not (costsPayable g v p ob idx (abCost ab))
                then return (Left "cost-unpayable")
                else do
                  cid <- freshCid
                  let entry = Entry { enCid = cid, enKind = EKAbility, enCtl = p, enSrc = oid
                                    , enIdx = idx, enSlots = [Slot t False | t <- tgts]
                                    , enSpecs = specs, enIt = Nothing, enEffects = Nothing }
                  mutQ (\s -> s { gChain = entry : gChain s })
                  emit ("ACTIVATE " ++ playerName p ++ " ~" ++ show cid ++ " #" ++ show oid ++ " "
                        ++ show idx ++ renderSlots (enSlots entry))
                  mapM_ (payCost p oid idx) (abCost ab)
                  return (Right ())
    _ -> return (Left "no-such-object")

payCost :: Player -> Int -> Int -> CostItem -> Eng ()
payCost p oid idx item = case item of
  CIEmber n -> do
    mutDep depPlayer (modP p (\ps -> ps { pEmber = pEmber ps - n }))
    when (n > 0) $ emit ("PAY " ++ playerName p ++ " ember " ++ show n)
  CISpire n -> do
    when (n > 0) $ emit ("PAY " ++ playerName p ++ " spire " ++ show n)
    changeSpire p (negate n)
  CIDiscard n -> replicateM_ n (discardOne p)
  CIExhaust -> setExhausted oid
  CISacSelf -> sacrificeObj oid
  CICounters n -> addCounters oid (negate n)
  CIOnce -> updField oid (\f -> f { fOnce = IS.insert idx (fOnce f) })
