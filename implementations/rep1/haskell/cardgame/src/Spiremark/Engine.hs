-- |
-- Module      : Spiremark.Engine
-- Description : The resumable game engine: setup, turn structure, actions.
--
-- 'newGame' performs the setup of SPEC.md section 8 and runs the match forward
-- to its first decision point.  'stepLine' then feeds the engine one script
-- line at a time; the engine validates it (section 24), applies it, and runs
-- forward again to the next decision point.  The match is simulated exactly
-- once; no state is ever copied to try an action.
module Spiremark.Engine
  ( Game
  , SetupError (..)
  , newGame
  , stepLine
  , finishGame
  , takeOutput
  , gameResult
  , gameOver
  ) where

import Control.Monad
import Control.Monad.State.Strict
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.Foldable (toList)
import Data.List (nub, partition)
import qualified Data.Map.Strict as M
import qualified Data.Sequence as Seq
import qualified Data.Set as Set

import Spiremark.Card.Print (cardBlock)
import Spiremark.Card.Types
import Spiremark.Engine.Chain
import Spiremark.Engine.Combat
import Spiremark.Engine.Core
import Spiremark.Engine.Derive
import Spiremark.Engine.Eval
import Spiremark.Engine.Report
import Spiremark.Engine.Types
import Spiremark.Match
import Spiremark.Random
import Spiremark.Types

-- | A running (or finished) match.
type Game = G

-- | Fatal setup problems that stop the match before it starts.
data SetupError = UnknownCard
  deriving (Eq, Show)

-- | Whether the match has ended.
gameOver :: Game -> Bool
gameOver = isOver

-- | The result as (winner, reason), once the match has ended.
gameResult :: Game -> Maybe (String, String)
gameResult = gResult

-- | Drain the output lines produced so far (oldest first).
takeOutput :: Game -> ([String], Game)
takeOutput g = (reverse (gOut g), g { gOut = [] })

emptyPState :: Int -> Int -> PState
emptyPState spire cap = PState
  { pSpire = spire, pEmber = 0, pCap = cap, pShield = 0
  , pVault = Seq.empty, pHand = Seq.empty, pAsh = Seq.empty, pRift = Seq.empty }

-- | Set up a match (SPEC.md section 8, steps 3-10).  The database has already
-- been validated.
newGame :: Setup -> CardDb -> Either SetupError Game
newGame su db
  | any (`M.notMember` db) [cid | (_, _, es) <- suZones su, (cid, _) <- es] = Left UnknownCard
  | otherwise = Right (execState (setup su db >> runForward) g0)
  where
    g0 = G
      { gCfg = Config { cfMaxCap = suMaxCap su, cfHandMax = suHandMax su
                      , cfTurnLimit = suTurnLimit su, cfFirst = suFirst su
                      , cfTrace = suTrace su }
      , gDb = db, gObjs = IM.empty, gField = Set.empty
      , gNextOid = 1, gNextTs = 1, gNextCid = 1, gNextEid = 1
      , gA = emptyPState (suSpire su) (suCapA su)
      , gB = emptyPState (suSpire su) (suCapB su)
      , gChain = [], gRecs = IM.empty, gDelayed = [], gPending = []
      , gTurn = 1, gActive = suFirst su, gPhase = PhDawn, gMode = MEnter PhDawn
      , gPass = 0, gHolder = suFirst su, gDealt = IS.empty
      , gLossA = Nothing, gLossB = Nothing, gResult = Nothing
      , gRng = mkRng (suSeed su), gSeq = 0, gOut = [], gDerived = Nothing }

setup :: Setup -> CardDb -> Eng ()
setup su db = do
  let first = suFirst su
  emit ("GAME-START " ++ playerName first)
  fieldObjs <- fmap concat $ forM [A, B] $ \p ->
    fmap concat $ forM [minBound .. maxBound] $ \zk -> do
      let entries = concat [es | (p', zk', es) <- suZones su, p' == p, zk' == zk]
          cids = [cid | (cid, n) <- entries, _ <- [1 .. n]]
      oids <- forM cids $ \cid -> newObject (db M.! cid) p (zoneOf zk)
      return [(o, p) | zk == ZField, o <- oids]
  forM_ fieldObjs $ \(o, p) -> setupEnterField o p
  when (suShuffle su) $ forM_ [A, B] $ \p -> do
    v <- gets (toList . pVault . pst p)
    r <- gets gRng
    let (v', r') = shuffle v r
    mutQ (\g -> modP p (\ps -> ps { pVault = Seq.fromList v' }) g { gRng = r' })
    emit ("SHUFFLE " ++ playerName p)
  drawFor False first (suOpening su)
  drawFor False (other first) (suOpening su)
  _ <- settle
  over <- gets isOver
  unless over $ beginTurn
  where
    zoneOf zk = case zk of
      ZDeck -> ZnVault
      ZHand -> ZnHand
      ZField -> ZnChain
      ZAsh -> ZnAsh
      ZRift -> ZnRift

beginTurn :: Eng ()
beginTurn = do
  g <- get
  emit ("TURN " ++ show (gTurn g) ++ " " ++ playerName (gActive g))
  mutQ (\s -> s { gMode = MEnter PhDawn })

-- ---------------------------------------------------------------------------
-- Running forward

-- | Run rules processing until a decision point (or the end of the match).
runForward :: Eng ()
runForward = do
  m <- gets gMode
  case m of
    MEnter ph -> enterPhase ph >> runForward
    _ -> return ()

setMode :: Mode -> Eng ()
setMode m = mutQ (\g -> g { gMode = m })

-- | Begin a priority round (SPEC.md 10.4).
startRound :: Eng ()
startRound = do
  mutQ (\g -> g { gPass = 0 })
  _ <- settle
  over <- gets isOver
  unless over $ mutQ (\g -> g { gHolder = gActive g, gMode = MAwait DPriority })

-- | A step without a priority round: drain, then continue to @next@.
drainThen :: Phase -> Eng ()
drainThen next = do
  drain
  over <- gets isOver
  unless over $ setMode (MEnter next)

fireDelayed :: When -> (Delayed -> Bool) -> Eng ()
fireDelayed w ok = do
  ds <- gets gDelayed
  let (fire, keep) = partition (\d -> dlWhen d == w && ok d) ds
  mutQ (\g -> g { gDelayed = keep })
  addPending [ Pending (dlCtl d) (dlTs d) (dlSrc d) 0 Nothing (Just d) | d <- fire ]

enterPhase :: Phase -> Eng ()
enterPhase ph = do
  mutQ (\g -> g { gPhase = ph })
  emit ("PHASE " ++ phaseName ph)
  g <- get
  let active = gActive g
  case ph of
    PhDawn -> do
      mx <- gets (cfMaxCap . gCfg)
      mutDep 0 (modP active (\ps -> ps { pCap = min (pCap ps + 1) mx }))
      forM_ [A, B] $ \p -> do
        mutDep depPlayer (modP p (\ps -> ps { pEmber = pCap ps }))
        ps <- gets (pst p)
        emit ("EMBER " ++ playerName p ++ " " ++ show (pEmber ps) ++ " " ++ show (pCap ps))
      v <- getView
      g1 <- get
      forM_ [o | o <- fieldOids g1, vCtl v o == active] setReady
      g2 <- get
      forM_ (fieldOids g2) $ \o ->
        updField o (\f -> f { fTenUsed = False, fOnce = IS.empty })
      collectScan EvTurnStart (SubPlayer active) (\_ _ -> True)
      collectScan EvYourTurnStart (SubPlayer active) (\_ c -> c == active)
      fireDelayed WYourNextTurnStart (\d -> dlCtl d == active)
      drainThen PhDraw
    PhDraw -> do
      first <- gets (cfFirst . gCfg)
      unless (gTurn g == 1 && active == first) $ drawFor True active 1
      drainThen PhMain1
    PhMain1 -> startRound
    PhClashAttack -> do
      _ <- settle
      over <- gets isOver
      unless over $ setMode (MAwait DAttackers)
    PhClashBlock -> do
      _ <- settle
      over <- gets isOver
      unless over $ setMode (MAwait DBlockers)
    PhClashRiposte -> do
      combatDamageStep True
      startRound
    PhClashDamage -> do
      combatDamageStep False
      startRound
    PhClashEnd -> do
      g1 <- get
      forM_ (fieldOids g1) $ \o ->
        when (inCombat (getObj o g1)) $ collectOne EvEndOfCombat o (SubObj o)
      fireDelayed WEndOfCombat (const True)
      startRound
    PhMain2 -> startRound
    PhDuskTrigger -> do
      collectScan EvTurnEnd (SubPlayer active) (\_ _ -> True)
      collectScan EvYourTurnEnd (SubPlayer active) (\_ c -> c == active)
      fireDelayed WTurnEnd (const True)
      startRound
    PhDuskDiscard -> do
      hm <- gets (cfHandMax . gCfg)
      let loop = do
            n <- gets (Seq.length . pHand . pst active)
            when (n > hm) $ discardOne active >> loop
      loop
      drainThen PhDuskCleanup
    PhDuskCleanup -> do
      cleanup
      drain
      over <- gets isOver
      unless over advanceTurn

cleanup :: Eng ()
cleanup = do
  g <- get
  forM_ (fieldOids g) $ \o ->
    updField o (\f -> f { fWounds = 0, fDoomed = False, fWard = 0 })
  mutDep 0 (\s -> s { gA = (gA s) { pShield = 0 }, gB = (gB s) { pShield = 0 } })
  turn <- gets gTurn
  recs <- gets (IM.elems . gRecs)
  let controlled = [ o | r <- recs, RDiscrete (DControl _) objs <- [rBody r], o <- objs ]
  forM_ controlled $ \o -> do
    mo <- gets (lookupObj o)
    forM_ mo $ \ob -> when (onField ob) $ updField o (\f -> f { fSince = turn })
  mut (\s -> s { gRecs = IM.filter isAuraRec (gRecs s) })
  mutQ (\s -> s { gDelayed = filter ((== WYourNextTurnStart) . dlWhen) (gDelayed s) })
  where
    isAuraRec r = case rBody r of
      RAura _ -> True
      _ -> False

advanceTurn :: Eng ()
advanceTurn = do
  g <- get
  let t = gTurn g + 1
      a = other (gActive g)
  mut (\s -> s { gTurn = t, gActive = a })
  if t > cfTurnLimit (gCfg g)
    then finishDraw "turn-limit"
    else beginTurn

-- | After a priority round ends (two passes on an empty Chain).
endRound :: Eng ()
endRound = do
  g <- get
  v <- getView
  case gPhase g of
    PhMain1 -> setMode (MEnter PhClashAttack)
    PhClashAttack -> setMode (MEnter PhClashBlock)
    PhClashBlock ->
      let rip = [ o | o <- fieldOids g, inCombat (getObj o g), hasKw v o Riposte
                    , cardType (oCard (getObj o g)) == Unit ]
       in setMode (MEnter (if null rip then PhClashDamage else PhClashRiposte))
    PhClashRiposte -> setMode (MEnter PhClashDamage)
    PhClashDamage -> setMode (MEnter PhClashEnd)
    PhClashEnd -> endCombat >> setMode (MEnter PhMain2)
    PhMain2 -> setMode (MEnter PhDuskTrigger)
    PhDuskTrigger -> setMode (MEnter PhDuskDiscard)
    _ -> return ()

-- ---------------------------------------------------------------------------
-- Script lines

rawLines :: [String] -> Eng ()
rawLines ls = mutQ (\g -> g { gOut = reverse ls ++ gOut g })

-- | Process one script line (given its 1-based line number).
stepLine :: Int -> ScriptLine -> Game -> Game
stepLine ln sl = execState (stepLineM ln sl)

stepLineM :: Int -> ScriptLine -> Eng ()
stepLineM ln sl = case sl of
  SBadSyntax -> rawLines ["ERR " ++ show ln ++ " bad-syntax"]
  SDump -> get >>= rawLines . dumpBlock
  SLegal -> get >>= rawLines . legalBlock
  SVault -> get >>= rawLines . vaultBlock
  SCard cid -> do
    db <- gets gDb
    rawLines (cardBlock db cid)
  SAction p act -> doAction ln p act

-- | Emit the end-of-script @RESULT pending none@ line if the match is running.
finishGame :: Game -> Game
finishGame g
  | isOver g = g
  | otherwise = execState (emit "RESULT pending none") g

doAction :: Int -> Player -> Action -> Eng ()
doAction ln p act = do
  g <- get
  let waiting = fmap fst (decisionLine g)
      err kind = rawLines ["ERR " ++ show ln ++ " " ++ kind]
      decisionOk = case (act, gMode g) of
        (Concede, _) -> True
        (Attack _, MAwait DAttackers) -> True
        (Block _, MAwait DBlockers) -> True
        (Pass, MAwait DPriority) -> True
        (Play _ _, MAwait DPriority) -> True
        (Act _ _ _, MAwait DPriority) -> True
        _ -> False
  if isOver g then err "game-over"
  else if waiting /= Just p then err "not-your-turn"
  else if not decisionOk then err "wrong-decision"
  else case act of
    Concede -> do
      recordLoss p "concede"
      _ <- lossCheck
      accepted
    Pass -> do
      emit ("PASS " ++ playerName p)
      n <- (+ 1) <$> gets gPass
      mutQ (\s -> s { gPass = n })
      if n == 1
        then mutQ (\s -> s { gHolder = other p })
        else do
          ch <- gets gChain
          if null ch
            then endRound
            else do
              mutQ (\s -> s { gPass = 0 })
              resolveTop
              _ <- settle
              over <- gets isOver
              unless over $ mutQ (\s -> s { gHolder = gActive s })
      accepted
    Play pos tgts -> do
      r <- playCard p pos tgts
      case r of
        Left e -> err e
        Right () -> afterPlay >> accepted
    Act o idx tgts -> do
      r <- activateAbility p o idx tgts
      case r of
        Left e -> err e
        Right () -> afterPlay >> accepted
    Attack os -> do
      v <- getView
      let dup = length (nub os) /= length os
          (legal, required) = attackersLegal g v os
      if dup then err "duplicate-attacker"
      else if not legal then err "illegal-attacker"
      else if not required then err "missing-required-attacker"
      else do
        if null os
          then setMode (MEnter PhMain2)
          else do
            declareAttackers os
            startRound
        accepted
    Block pairs -> do
      v <- getView
      let bs = map fst pairs
          dup = length (nub bs) /= length bs
      if dup then err "duplicate-blocker"
      else if not (all (\(b, a) -> canBlock g v b a) pairs) then err "illegal-blocker"
      else if not (blockProvokeOk g v pairs) then err "missing-required-block"
      else do
        declareBlockers pairs
        startRound
        accepted
  where
    afterPlay = do
      mutQ (\s -> s { gPass = 0, gHolder = p })
      acted <- settle
      over <- gets isOver
      when (acted && not over) $ mutQ (\s -> s { gPass = 0, gHolder = gActive s })
    accepted = do
      runForward
      tr <- gets (cfTrace . gCfg)
      case tr of
        TraceNone -> return ()
        TraceLegal -> get >>= rawLines . legalBlock
        TraceState -> get >>= rawLines . dumpBlock
