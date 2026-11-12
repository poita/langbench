-- |
-- Module      : Spiremark.Engine.Core
-- Description : Primitive state changes of the rules engine (SPEC.md 17, 18).
--
-- Every function here is one of the atomic procedures of section 17 (dealing
-- damage, destroying, drawing, ...) together with the event emission and
-- trigger collection that belong to it, plus the machinery they share: the
-- event log, zone moves, Field entry and exit, trigger collection and the
-- end-of-match bookkeeping.
module Spiremark.Engine.Core
  ( -- * Log and state helpers
    emit
  , mut
  , mutQ
  , mutDep
  , depZone
  , depPlayer
  , depField
  , signed
  , updObj
  , updField
  , updObjZ
  , objIs
  , getG
    -- * Zones and objects
  , newObject
  , moveTo
  , removeFromZone
  , enterField
  , setupEnterField
  , leaveField
  , removeFromCombat
    -- * Procedures of section 17
  , dealDamage
  , destroyObj
  , sacrificeObj
  , exileObj
  , bounceObj
  , drawOne
  , drawFor
  , discardOne
  , millOne
  , changeSpire
  , gainEmber
  , raiseCap
  , setReady
  , setExhausted
  , addCounters
  , newTimestamp
  , addRecord
  , zoneName
    -- * Triggers
  , collectOne
  , collectScan
  , collectGone
  , addPending
    -- * State checks and match end
  , recordLoss
  , lossCheck
  , stateChecks
  , finishDraw
  ) where

import Control.Monad
import Control.Monad.State.Strict
import Data.Bits ((.&.))
import qualified Data.IntMap.Strict as IM
import Data.Maybe (isJust)
import Data.Sequence (Seq, ViewL (..), (|>))
import qualified Data.Sequence as Seq
import qualified Data.Set as Set

import Spiremark.Card.Types
import Spiremark.Engine.Derive
import Spiremark.Engine.Eval
import Spiremark.Engine.Types
import Spiremark.Types

-- ---------------------------------------------------------------------------
-- Log and state helpers

getG :: Eng G
getG = get

-- | Append an event line, numbering it.
emit :: String -> Eng ()
emit s = modify' $ \g ->
  let n = gSeq g + 1 in g { gSeq = n, gOut = (show n ++ " " ++ s) : gOut g }

-- | Modify the state and drop the cached derivation.
mut :: (G -> G) -> Eng ()
mut f = modify' (invalidate . f)

-- | Modify state that no characteristic derivation can depend on.
mutQ :: (G -> G) -> Eng ()
mutQ = modify'

-- | Modify the state, dropping the cached derivation only if the aura records
-- read the given state class (0 never invalidates).
mutDep :: Int -> (G -> G) -> Eng ()
mutDep bit f = modify' $ \g ->
  let g' = f g
   in case gDerived g' of
        Just d | dDeps d .&. bit == 0 -> g'
        _ -> g' { gDerived = Nothing }

-- | State classes for 'mutDep'.
depZone, depPlayer, depField :: Int
depZone = 1
depPlayer = 2
depField = 4

-- | Render a signed number with an explicit sign.
signed :: Int -> String
signed n | n >= 0 = '+' : show n
         | otherwise = show n

updObj :: Int -> (Obj -> Obj) -> Eng ()
updObj o f = mut (\g -> g { gObjs = IM.adjust f o (gObjs g) })

-- | Update per-object Field state that is not structural (wounds, exhaustion,
-- combat status, ...).
updField :: Int -> (FieldSt -> FieldSt) -> Eng ()
updField o f = mutDep depField (\g -> g { gObjs = IM.adjust (\ob -> ob { oF = f (oF ob) }) o (gObjs g) })

-- | Update an object outside the Field (its zone label).
updObjZ :: Int -> (Obj -> Obj) -> Eng ()
updObjZ o f = mutDep depZone (\g -> g { gObjs = IM.adjust f o (gObjs g) })

objIs :: Int -> Eng Obj
objIs o = gets (getObj o)

zoneName :: Zone -> String
zoneName z = case z of
  ZnVault -> "vault"; ZnHand -> "hand"; ZnField -> "field"
  ZnAsh -> "ash"; ZnRift -> "rift"; ZnChain -> "chain"

pn :: Player -> String
pn = playerName

cid' :: Obj -> String
cid' = cardId . oCard

-- ---------------------------------------------------------------------------
-- Zones

zoneGet :: Zone -> PState -> Maybe (Seq Int)
zoneGet z ps = case z of
  ZnVault -> Just (pVault ps)
  ZnHand -> Just (pHand ps)
  ZnAsh -> Just (pAsh ps)
  ZnRift -> Just (pRift ps)
  _ -> Nothing

zoneSet :: Zone -> Seq Int -> PState -> PState
zoneSet z s ps = case z of
  ZnVault -> ps { pVault = s }
  ZnHand -> ps { pHand = s }
  ZnAsh -> ps { pAsh = s }
  ZnRift -> ps { pRift = s }
  _ -> ps

-- | Allocate a new object (not yet in any zone sequence).
newObject :: Card -> Player -> Zone -> Eng Int
newObject c owner z = do
  g <- get
  let oid = gNextOid g
      ob = Obj { oOid = oid, oCard = c, oOwner = owner, oTs = 0, oZone = z
               , oLastCtl = owner, oF = freshFieldSt owner 0 }
  mutDep depZone (\s -> s { gNextOid = oid + 1, gObjs = IM.insert oid ob (gObjs s) })
  appendZone oid owner z
  return oid

appendZone :: Int -> Player -> Zone -> Eng ()
appendZone oid owner z = case z of
  ZnVault -> app
  ZnHand -> app
  ZnAsh -> app
  ZnRift -> app
  _ -> return ()
  where
    app = mutDep depZone (modP owner (\ps -> maybe ps (\s -> zoneSet z (s |> oid) ps) (zoneGet z ps)))

-- | Take a card out of whichever zone sequence holds it.
removeFromZone :: Int -> Eng ()
removeFromZone oid = do
  ob <- objIs oid
  let z = oZone ob
  case z of
    ZnVault -> do
      -- vault removals are usually from the top
      mutDep depZone (modP (oOwner ob) (\ps -> ps { pVault = delSeq oid (pVault ps) }))
    _ -> mutDep depZone (modP (oOwner ob) (\ps -> maybe ps (\s -> zoneSet z (delSeq oid s) ps) (zoneGet z ps)))
  where
    delSeq o s = case Seq.viewl s of
      x :< rest | x == o -> rest
      _ -> case Seq.elemIndexL o s of
        Just i -> Seq.deleteAt i s
        Nothing -> s

-- | Move a non-Field object to another zone of its owner (appending).
moveTo :: Int -> Zone -> Eng ()
moveTo oid z = do
  removeFromZone oid
  updObjZ oid (\ob -> ob { oZone = z })
  ob <- objIs oid
  appendZone oid (oOwner ob) z

-- ---------------------------------------------------------------------------
-- Timestamps and records

newTimestamp :: Eng Int
newTimestamp = do
  t <- gets gNextTs
  mutQ (\g -> g { gNextTs = t + 1 })
  return t

-- | Create a continuous-effect record with fresh timestamp and eid.
addRecord :: Player -> Int -> RBody -> Eng ()
addRecord c src body = do
  ts <- newTimestamp
  g <- get
  let eid = gNextEid g
      r = Rec { rEid = eid, rTs = ts, rCtl = c, rSrc = src, rBody = body }
  mut (\s -> s { gNextEid = eid + 1, gRecs = IM.insert eid r (gRecs s) })

-- ---------------------------------------------------------------------------
-- Entering and leaving the Field

-- | Put an object on the Field without events or triggers (setup).
setupEnterField :: Int -> Player -> Eng ()
setupEnterField oid ctl = placeOnField oid ctl 0

placeOnField :: Int -> Player -> Int -> Eng ()
placeOnField oid ctl since = do
  removeFromZone oid
  ts <- newTimestamp
  mut $ \g ->
    g { gObjs = IM.adjust (\ob -> ob { oZone = ZnField, oTs = ts, oF = freshFieldSt ctl since }) oid (gObjs g)
      , gField = Set.insert (ts, oid) (gField g) }
  ob <- objIs oid
  forM_ (cardAbilities (oCard ob)) $ \ab ->
    when (abKind ab == AKAura) $ addRecord ctl oid (RAura ab)

-- | Enter the Field (SPEC.md 17.17): emits @ARRIVE@ and collects triggers.
enterField :: Int -> Player -> Eng ()
enterField oid ctl = do
  turn <- gets gTurn
  placeOnField oid ctl turn
  ob <- objIs oid
  emit ("ARRIVE #" ++ show oid ++ " " ++ cid' ob)
  collectOne EvArrive oid (SubObj oid)
  when (cardType (oCard ob) == Unit) $ do
    v <- getView
    let c = vCtl v oid
    collectScan EvAllyArrive (SubObj oid) (\x xc -> x /= oid && xc == c)
    collectScan EvEnemyArrive (SubObj oid) (\x xc -> x /= oid && xc /= c)

-- | Detach an object from combat (SPEC.md 7.5 \"Removal from combat\").
removeFromCombat :: Int -> Eng ()
removeFromCombat oid = do
  ob <- objIs oid
  let fs = oF ob
  forM_ (fBlocking fs) $ \a -> do
    ma <- gets (lookupObj a)
    forM_ ma $ \ao -> when (onField ao) $
      updField a (\f -> f { fBlockers = filter (/= oid) (fBlockers f) })
  when (fAttacking fs) $
    forM_ (fBlockers fs) $ \b -> do
      mb <- gets (lookupObj b)
      forM_ mb $ \bo -> when (onField bo) $
        updField b (\f -> f { fBlocking = Nothing })
  when (fAttacking fs || isJust (fBlocking fs) || not (null (fBlockers fs)) || fBlocked fs) $
    updField oid (\f -> f { fAttacking = False, fBlocking = Nothing, fBlockers = [], fBlocked = False })

-- | Remove an object from the Field into another zone of its owner.  Returns
-- the controller it had at that moment.
leaveField :: Int -> Zone -> Eng Player
leaveField oid dest = do
  v <- getView
  ob <- objIs oid
  let c = vCtl v oid
  removeFromCombat oid
  mut $ \g ->
    g { gField = Set.delete (oTs ob, oid) (gField g)
      , gRecs = IM.filter (not . auraOf oid) (gRecs g)
      , gObjs = IM.adjust (\o -> o { oZone = dest, oLastCtl = c, oF = freshFieldSt (oOwner o) 0 }) oid (gObjs g)
      }
  appendZone oid (oOwner ob) dest
  return c
  where
    auraOf o r = rSrc r == o && case rBody r of
      RAura _ -> True
      _ -> False

-- ---------------------------------------------------------------------------
-- Triggers

addPending :: [Pending] -> Eng ()
addPending [] = return ()
addPending ps = mutQ (\g -> g { gPending = reverse ps ++ gPending g })

-- | Collect @ev@ from one specific Field object.
collectOne :: Event -> Int -> Subject -> Eng ()
collectOne ev oid it = do
  d <- getDerived
  g <- get
  case lookupObj oid g of
    Just o | onField o, not (isStripped d oid) ->
      let c = IM.findWithDefault (oOwner o) oid (dCtl d)
       in addPending [ Pending c (oTs o) oid (abIndex ab) (Just it) Nothing
                     | ab <- cardAbilities (oCard o), abKind ab == AKOn ev ]
    _ -> return ()

-- | Collect @ev@ from every listening Field object accepted by the predicate
-- on (object id, current controller).
collectScan :: Event -> Subject -> (Int -> Player -> Bool) -> Eng ()
collectScan ev it ok = do
  d <- getDerived
  g <- get
  addPending
    [ Pending c (oTs o) oid (abIndex ab) (Just it) Nothing
    | oid <- fieldOids g
    , not (isStripped d oid)
    , let o = getObj oid g
    , let c = IM.findWithDefault (oOwner o) oid (dCtl d)
    , ok oid c
    , ab <- cardAbilities (oCard o)
    , abKind ab == AKOn ev
    ]

-- | Collect @leave@/@dies@ from an object that has already left the Field.
collectGone :: Event -> Int -> Subject -> Eng ()
collectGone ev oid it = do
  o <- objIs oid
  addPending
    [ Pending (oLastCtl o) (oTs o) oid (abIndex ab) (Just it) Nothing
    | ab <- cardAbilities (oCard o), abKind ab == AKOn ev ]

-- ---------------------------------------------------------------------------
-- Section 17 procedures

-- | Deal damage from a source object to a target (SPEC.md 17.1).
dealDamage :: Int -> Target -> Int -> Eng ()
dealDamage src tgt n
  | n <= 0 = return ()
  | otherwise = do
      g <- get
      case tgt of
        TgtObj o -> case lookupObj o g of
          Just ob | onField ob, cardType (oCard ob) == Unit -> go
          _ -> return ()
        TgtPlayer _ -> go
        TgtEntry _ -> return ()
  where
    go = do
      v <- getView
      g <- get
      let (plating, pool) = case tgt of
            TgtObj o -> (platingTotal v o, fWard (oF (getObj o g)))
            TgtPlayer p -> (0, pShield (pst p g))
            TgtEntry _ -> (0, 0)
          afterPlating = max 0 (n - plating)
          u = min pool afterPlating
          m = afterPlating - u
          prevented = n - m
      when (u > 0) $ case tgt of
        TgtObj o -> updField o (\f -> f { fWard = fWard f - u })
        TgtPlayer p -> mutDep 0 (modP p (\ps -> ps { pShield = pShield ps - u }))
        TgtEntry _ -> return ()
      when (prevented > 0) $ emit ("PREVENT " ++ renderTarget tgt ++ " " ++ show prevented)
      when (m > 0) $ applyDamage v m
    applyDamage v m = do
      emit ("DAMAGE #" ++ show src ++ " " ++ renderTarget tgt ++ " " ++ show m)
      case tgt of
        TgtObj o -> updField o (\f -> f { fWounds = fWounds f + m })
        TgtPlayer p -> do
          mutDep depPlayer (modP p (\ps -> ps { pSpire = pSpire ps - m }))
          new <- gets (pSpire . pst p)
          emit ("SPIRE " ++ pn p ++ " -" ++ show m ++ " " ++ show new)
          spireLossTriggers p
        TgtEntry _ -> return ()
      g <- get
      v' <- getView
      let srcObj = lookupObj src g
          srcLive = case srcObj of
            Just so -> onField so && cardType (oCard so) == Unit
            Nothing -> False
          _ = v
      case tgt of
        TgtObj o | srcLive && hasKw v' src Venom -> do
          updField o (\f -> f { fDoomed = True })
          emit ("DOOM #" ++ show o)
        _ -> return ()
      when (srcLive && hasKw v' src Siphon) $ do
        let c = vCtl v' src
        mutDep depPlayer (modP c (\ps -> ps { pSpire = pSpire ps + m }))
        new <- gets (pSpire . pst c)
        emit ("SPIRE " ++ pn c ++ " +" ++ show m ++ " " ++ show new)
      g2 <- get
      case tgt of
        TgtObj o | maybe False onField (lookupObj o g2) ->
          collectOne EvDamaged o (SubObj src)
        _ -> return ()
      when (maybe False onField (lookupObj src g2)) $
        collectOne EvDealsDamage src (case tgt of
          TgtObj o -> SubObj o
          TgtPlayer p -> SubPlayer p
          TgtEntry _ -> SubPlayer A)

spireLossTriggers :: Player -> Eng ()
spireLossTriggers p = do
  collectScan EvSpireLoss (SubPlayer p) (\_ c -> c == p)
  collectScan EvEnemySpireLoss (SubPlayer p) (\_ c -> c /= p)

-- | Destroy an object on the Field (SPEC.md 17.3), applying @tenacity@.
destroyObj :: Int -> Eng ()
destroyObj oid = do
  g <- get
  case lookupObj oid g of
    Just ob | onField ob -> do
      v <- getView
      if hasKw v oid Tenacity && not (fTenUsed (oF ob))
        then do
          updField oid (\f -> f { fTenUsed = True, fWounds = 0, fDoomed = False })
          emit ("TENACITY #" ++ show oid)
        else die "DESTROY" ob
    _ -> return ()

-- | Sacrifice an object on the Field (SPEC.md 17.4).
sacrificeObj :: Int -> Eng ()
sacrificeObj oid = do
  g <- get
  case lookupObj oid g of
    Just ob | onField ob -> die "SACRIFICE" ob
    _ -> return ()

die :: String -> Obj -> Eng ()
die word ob = do
  let oid = oOid ob
  c <- leaveField oid ZnAsh
  emit (word ++ " #" ++ show oid ++ " " ++ cid' ob)
  collectGone EvDies oid (SubObj oid)
  collectGone EvLeave oid (SubObj oid)
  when (cardType (oCard ob) == Unit) $ do
    collectScan EvAllyDies (SubObj oid) (\_ xc -> xc == c)
    collectScan EvEnemyDies (SubObj oid) (\_ xc -> xc /= c)

-- | Exile an object from any zone (SPEC.md 17.5).
exileObj :: Int -> Eng ()
exileObj oid = do
  ob <- objIs oid
  case oZone ob of
    ZnChain -> return ()
    ZnField -> do
      _ <- leaveField oid ZnRift
      emit ("EXILE #" ++ show oid ++ " " ++ cid' ob ++ " field")
      collectGone EvLeave oid (SubObj oid)
    z -> do
      moveTo oid ZnRift
      emit ("EXILE #" ++ show oid ++ " " ++ cid' ob ++ " " ++ zoneName z)

-- | Bounce a Field object to its owner's hand (SPEC.md 17.6).
bounceObj :: Int -> Eng ()
bounceObj oid = do
  g <- get
  case lookupObj oid g of
    Just ob | onField ob -> do
      _ <- leaveField oid ZnHand
      emit ("BOUNCE #" ++ show oid ++ " " ++ cid' ob)
      collectGone EvLeave oid (SubObj oid)
    _ -> return ()

-- | Record a loss reason unless the player already has one.
recordLoss :: Player -> String -> Eng ()
recordLoss p r = mutQ $ \g -> case p of
  A -> g { gLossA = maybe (Just r) Just (gLossA g) }
  B -> g { gLossB = maybe (Just r) Just (gLossB g) }

-- | Draw one card (SPEC.md 17.7); 'False' when the Vault was empty.  The flag
-- says whether @you-draw@ triggers are collected (not during setup).
drawOne :: Bool -> Player -> Eng Bool
drawOne fire p = do
  v <- gets (pVault . pst p)
  case Seq.viewl v of
    EmptyL -> do
      emit ("DRAW-EMPTY " ++ pn p)
      recordLoss p "vault"
      return False
    o :< rest -> do
      mutDep depZone (modP p (\ps -> ps { pVault = rest, pHand = pHand ps |> o }))
      updObjZ o (\ob -> ob { oZone = ZnHand })
      ob <- objIs o
      emit ("DRAW " ++ pn p ++ " #" ++ show o ++ " " ++ cid' ob)
      when fire $ collectScan EvYouDraw (SubObj o) (\_ c -> c == p)
      return True

-- | Draw up to @n@ cards, stopping at the first empty Vault.
drawFor :: Bool -> Player -> Int -> Eng ()
drawFor fire p n = when (n > 0) $ do
  ok <- drawOne fire p
  when ok (drawFor fire p (n - 1))

-- | Discard the card at hand position 1 (SPEC.md 17.8).
discardOne :: Player -> Eng ()
discardOne p = do
  h <- gets (pHand . pst p)
  case Seq.viewl h of
    EmptyL -> return ()
    o :< _ -> do
      moveTo o ZnAsh
      ob <- objIs o
      emit ("DISCARD " ++ pn p ++ " #" ++ show o ++ " " ++ cid' ob)

-- | Mill the top card of the Vault (SPEC.md 17.9).
millOne :: Player -> Eng ()
millOne p = do
  v <- gets (pVault . pst p)
  case Seq.viewl v of
    EmptyL -> return ()
    o :< _ -> do
      moveTo o ZnAsh
      ob <- objIs o
      emit ("MILL " ++ pn p ++ " #" ++ show o ++ " " ++ cid' ob)

-- | Change Spire by a signed amount (SPEC.md 17.10).
changeSpire :: Player -> Int -> Eng ()
changeSpire p n = when (n /= 0) $ do
  mutDep depPlayer (modP p (\ps -> ps { pSpire = pSpire ps + n }))
  new <- gets (pSpire . pst p)
  emit ("SPIRE " ++ pn p ++ " " ++ signed n ++ " " ++ show new)
  when (n < 0) $ spireLossTriggers p

-- | Gain Ember (SPEC.md 17.11).
gainEmber :: Player -> Int -> Eng ()
gainEmber p n = when (n > 0) $ do
  mutDep depPlayer (modP p (\ps -> ps { pEmber = pEmber ps + n }))
  new <- gets (pEmber . pst p)
  emit ("EMBERGAIN " ++ pn p ++ " " ++ show n ++ " " ++ show new)

-- | Raise the Ember cap (SPEC.md 17.12).
raiseCap :: Player -> Int -> Eng ()
raiseCap p n = when (n > 0) $ do
  mx <- gets (cfMaxCap . gCfg)
  mutDep 0 (modP p (\ps -> ps { pCap = min (pCap ps + n) mx }))
  new <- gets (pCap . pst p)
  emit ("CAP " ++ pn p ++ " " ++ show n ++ " " ++ show new)

-- | Make a Field object ready; event only on change (SPEC.md 17.15).
setReady :: Int -> Eng ()
setReady o = do
  ob <- objIs o
  when (onField ob && fExhausted (oF ob)) $ do
    updField o (\f -> f { fExhausted = False })
    emit ("READY #" ++ show o)

setExhausted :: Int -> Eng ()
setExhausted o = do
  ob <- objIs o
  when (onField ob && not (fExhausted (oF ob))) $ do
    updField o (\f -> f { fExhausted = True })
    emit ("EXHAUST #" ++ show o)

-- | Add signed charge counters, floored at zero (SPEC.md 17.14).
addCounters :: Int -> Int -> Eng ()
addCounters o n = do
  ob <- objIs o
  when (onField ob) $ do
    let old = fCounters (oF ob)
        new = max 0 (old + n)
    when (new /= old) $ do
      updObj o (\ob -> ob { oF = (oF ob) { fCounters = new } })
      emit ("COUNTERS #" ++ show o ++ " " ++ signed (new - old) ++ " " ++ show new)

-- ---------------------------------------------------------------------------
-- State checks and match end

-- | Section 18 step 1: losses by Spire, then end the match if anyone lost.
-- Returns whether the match ended.
lossCheck :: Eng Bool
lossCheck = do
  g <- get
  when (pSpire (gA g) <= 0) $ recordLoss A "spire"
  when (pSpire (gB g) <= 0) $ recordLoss B "spire"
  g' <- get
  case (gLossA g', gLossB g') of
    (Nothing, Nothing) -> return False
    (la, lb) -> do
      forM_ la $ \r -> emit ("LOSE A " ++ r)
      forM_ lb $ \r -> emit ("LOSE B " ++ r)
      let (winner, reason) = case (la, lb) of
            (Just r, Nothing) -> ("B", r)
            (Nothing, Just r) -> ("A", r)
            (Nothing, Nothing) -> ("draw", "")
            (Just r, Just _) -> ("draw", r)
      emit ("RESULT " ++ winner ++ " " ++ reason)
      mutQ (\s -> s { gResult = Just (winner, reason), gMode = MOver })
      return True

-- | End the match as a draw by turn limit.
finishDraw :: String -> Eng ()
finishDraw reason = do
  emit ("RESULT draw " ++ reason)
  mutQ (\s -> s { gResult = Just ("draw", reason), gMode = MOver })

-- | One run of the state checks (SPEC.md 18); 'True' when it acted.
stateChecks :: Eng Bool
stateChecks = do
  ended <- lossCheck
  if ended
    then return True
    else do
      v <- getView
      g <- get
      let victims =
            [ o
            | o <- fieldOids g
            , let ob = getObj o g
            , cardType (oCard ob) == Unit
            , vCore v o <= fWounds (oF ob) || fDoomed (oF ob)
            ]
      forM_ victims destroyObj
      return (not (null victims))
