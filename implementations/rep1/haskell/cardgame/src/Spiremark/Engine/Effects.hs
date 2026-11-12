-- |
-- Module      : Spiremark.Engine.Effects
-- Description : The effect interpreter (SPEC.md 6.8).
module Spiremark.Engine.Effects
  ( execEffects
  , execEffect
  , evalIn
  ) where

import Control.Monad
import Control.Monad.State.Strict
import qualified Data.Map.Strict as M
import Data.Sequence ((|>))
import qualified Data.Sequence as Seq
import Data.Foldable (toList)

import Spiremark.Card.Types
import Spiremark.Engine.Core
import Spiremark.Engine.Derive
import Spiremark.Engine.Eval
import Spiremark.Engine.Types
import Spiremark.Types

-- | Run a pure/PRNG evaluation in the engine, with the current derivation.
evalIn :: Ctx -> (Env -> Ev a) -> Eng a
evalIn cx f = do
  d <- getDerived
  g <- get
  let env = Env g (viewOf g d) cx True
      (a, r) = runState (f env) (gRng g)
  mutQ (\s -> s { gRng = r })
  return a

execEffects :: Ctx -> [Effect] -> Eng ()
execEffects cx = mapM_ (execEffect cx)

fieldObjs :: [Int] -> Eng [Int]
fieldObjs os = do
  g <- get
  return [o | o <- os, maybe False onField (lookupObj o g)]

players :: Ctx -> PSel -> Eng [Player]
players cx ps = evalIn cx (\env -> evalPSel env ps)

sel :: Ctx -> Sel -> Eng [Int]
sel cx s = evalIn cx (\env -> evalSel env s)

amt :: Ctx -> Amt -> Eng Int
amt cx a = evalIn cx (\env -> evalAmt env a)

-- | Execute one effect completely.
execEffect :: Ctx -> Effect -> Eng ()
execEffect cx eff = case eff of
  EDamage a ds -> do
    n <- amt cx a
    when (n > 0) $ do
      ts <- evalIn cx (\env -> evalDSel env ds)
      forM_ ts $ \t -> dealDamage (cxSrc cx) t n
  EDestroy s -> sel cx s >>= mapM_ destroyObj
  ESacrifice s -> sel cx s >>= mapM_ sacrificeObj
  EExile s -> sel cx s >>= mapM_ exileObj
  EBounce s -> sel cx s >>= mapM_ bounceObj
  EDraw a ps -> counted a ps (\p n -> drawFor True p n)
  EDiscard a ps -> counted a ps (\p n -> replicateM_ n (discardOne p))
  EMill a ps -> counted a ps (\p n -> replicateM_ n (millOne p))
  ESpire a ps -> do
    n <- amt cx a
    ps' <- players cx ps
    forM_ ps' $ \p -> changeSpire p n
  EEmber a ps -> counted a ps gainEmber
  ECap a ps -> counted a ps raiseCap
  EModify a b s -> do
    e <- amt cx a
    c <- amt cx b
    objs <- sel cx s >>= fieldObjs
    record (DModify e c) objs
    forM_ objs $ \o -> emit ("BUFF #" ++ show o ++ " " ++ show e ++ " " ++ show c)
  ESetbody a b s -> do
    e <- amt cx a
    c <- amt cx b
    objs <- sel cx s >>= fieldObjs
    record (DSetbody e c) objs
    forM_ objs $ \o -> emit ("SETBODY #" ++ show o ++ " " ++ show e ++ " " ++ show c)
  ESwapstats s -> do
    objs <- sel cx s >>= fieldObjs
    record DSwap objs
    forM_ objs $ \o -> emit ("SWAP #" ++ show o)
  EGrant spec s -> do
    objs <- sel cx s >>= fieldObjs
    record (DGrant spec) objs
    forM_ objs $ \o -> emit ("GRANT #" ++ show o ++ " " ++ renderKw spec)
  EStrip s -> do
    objs <- sel cx s >>= fieldObjs
    record DStrip objs
    forM_ objs $ \o -> emit ("STRIP #" ++ show o)
  EControl s -> do
    objs <- sel cx s >>= fieldObjs
    record (DControl (cxCtl cx)) objs
    turn <- gets gTurn
    forM_ objs $ \o -> do
      updField o (\f -> f { fSince = turn })
      removeFromCombat o
      emit ("CONTROL #" ++ show o ++ " " ++ playerName (cxCtl cx))
  ECounters a s -> do
    n <- amt cx a
    objs <- sel cx s >>= fieldObjs
    forM_ objs $ \o -> addCounters o n
  EReady s -> sel cx s >>= mapM_ setReady
  EExhaust s -> sel cx s >>= mapM_ setExhausted
  EDoom s -> do
    objs <- sel cx s >>= fieldObjs
    g <- get
    forM_ objs $ \o -> when (cardType (oCard (getObj o g)) == Unit) $ do
      updField o (\f -> f { fDoomed = True })
      emit ("DOOM #" ++ show o)
  EWard a s -> do
    n <- amt cx a
    when (n > 0) $ do
      objs <- sel cx s >>= fieldObjs
      forM_ objs $ \o -> do
        updField o (\f -> f { fWard = fWard f + n })
        pool <- gets (fWard . oF . getObj o)
        emit ("WARD #" ++ show o ++ " " ++ show n ++ " " ++ show pool)
  EShield a ps -> do
    n <- amt cx a
    when (n > 0) $ do
      ps' <- players cx ps
      forM_ ps' $ \p -> do
        mutDep 0 (modP p (\st -> st { pShield = pShield st + n }))
        pool <- gets (pShield . pst p)
        emit ("SHIELD " ++ playerName p ++ " " ++ show n ++ " " ++ show pool)
  ESummon cid a ps -> counted a ps $ \p n -> replicateM_ n (create cid p True)
  EConjure cid a ps -> counted a ps $ \p n -> replicateM_ n (create cid p False)
  EReanimate s -> do
    objs <- sel cx s
    forM_ objs $ \o -> do
      ob <- objIs o
      when (oZone ob == ZnAsh && cardType (oCard ob) == Unit) $
        enterField o (cxCtl cx)
  ERecall s -> do
    objs <- sel cx s
    forM_ objs $ \o -> do
      ob <- objIs o
      when (oZone ob == ZnAsh) $ do
        moveTo o ZnHand
        emit ("RECALL #" ++ show o ++ " " ++ cardId (oCard ob))
  ENegate n -> case drop (n - 1) (cxSlots cx) of
    (Slot (TgtEntry c) False : _) | n >= 1 -> negateEntry c
    _ -> return ()
  EDig k fs ps -> do
    ps' <- players cx ps
    forM_ ps' $ \p -> dig cx k fs p
  EDelay w es -> do
    ts <- newTimestamp
    let dl = Delayed
          { dlTs = ts, dlCtl = cxCtl cx, dlWhen = w, dlSrc = cxSrc cx
          , dlSlots = [Slot (slTarget s) False | s <- cxSlots cx]
          , dlSpecs = cxSpecs cx, dlEffects = es }
    mutQ (\g -> g { gDelayed = gDelayed g ++ [dl] })
    emit ("DELAY " ++ playerName (cxCtl cx) ++ " " ++ whenName w)
  EIf c t f -> do
    ok <- evalIn cx (\env -> evalCond env c)
    execEffects cx (if ok then t else f)
  EEach s es -> do
    objs <- sel cx s
    g <- get
    let zs = [(o, oZone (getObj o g)) | o <- objs]
    forM_ zs $ \(o, z) -> do
      cur <- gets (oZone . getObj o)
      when (cur == z) $ execEffects cx { cxThat = Just o } es
  ERepeat a es -> do
    n <- amt cx a
    replicateM_ n (execEffects cx es)
  ENothing -> return ()
  where
    counted a ps f = do
      n <- amt cx a
      when (n > 0) $ do
        ps' <- players cx ps
        forM_ ps' $ \p -> f p n
    record k objs = addRecord (cxCtl cx) (cxSrc cx) (RDiscrete k objs)

-- | Create a card object for a player: on the Field (summon) or in hand.
create :: String -> Player -> Bool -> Eng ()
create cid p toField = do
  db <- gets gDb
  case M.lookup cid db of
    Nothing -> return ()
    Just c -> do
      o <- newObject c p (if toField then ZnChain else ZnHand)
      emit ("CREATE #" ++ show o ++ " " ++ cid ++ " " ++ (if toField then "field" else "hand"))
      when toField $ enterField o p

-- | Remove an entry from the Chain (SPEC.md 17.20).
negateEntry :: Int -> Eng ()
negateEntry c = do
  ch <- gets gChain
  case filter ((== c) . enCid) ch of
    [] -> return ()
    (e : _) -> do
      mutQ (\g -> g { gChain = filter ((/= c) . enCid) (gChain g) })
      emit ("NEGATE ~" ++ show c)
      when (enKind e `elem` [EKRite, EKUnit, EKRelic]) $ do
        moveTo (enSrc e) ZnAsh
        ob <- objIs (enSrc e)
        emit ("SPENT #" ++ show (enSrc e) ++ " " ++ cardId (oCard ob))

-- | Look at the top cards of a Vault and take the first match (SPEC.md 17.21).
dig :: Ctx -> Int -> [Filter] -> Player -> Eng ()
dig cx k fs p = do
  v <- gets (pVault . pst p)
  let n = max 0 (min k (Seq.length v))
      (top, rest) = Seq.splitAt n v
      topL = toList top
  mutDep depZone (modP p (\ps -> ps { pVault = rest }))
  matches <- forM topL $ \o -> do
    d <- getDerived
    g <- get
    let env = Env g (viewOf g d) cx True
    return (matchFilters env (getObj o g) fs)
  let firstIdx = lookup True (zip matches [0 :: Int ..])
  remaining <- case firstIdx of
    Just i -> do
      let o = topL !! i
      mutDep depZone (modP p (\ps -> ps { pHand = pHand ps |> o }))
      updObjZ o (\ob -> ob { oZone = ZnHand })
      ob <- objIs o
      emit ("DIG " ++ playerName p ++ " #" ++ show o ++ " " ++ cardId (oCard ob))
      return (take i topL ++ drop (i + 1) topL)
    Nothing -> do
      emit ("DIG-MISS " ++ playerName p)
      return topL
  forM_ remaining $ \o -> do
    mutDep depZone (modP p (\ps -> ps { pVault = pVault ps |> o }))
    ob <- objIs o
    emit ("BOTTOM " ++ playerName p ++ " #" ++ show o ++ " " ++ cardId (oCard ob))
