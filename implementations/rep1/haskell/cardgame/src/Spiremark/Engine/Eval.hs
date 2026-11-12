-- |
-- Module      : Spiremark.Engine.Eval
-- Description : Evaluation of selectors, filters, amounts and conditions.
--
-- Everything here is read-only with respect to the game state; the only
-- side effect is drawing from the PRNG for @random-unit@, threaded through the
-- 'Ev' monad.  Evaluation is parameterised by a 'View' of current (or, for
-- auras, base) characteristics so the same code serves both ordinary
-- evaluation and the layer derivation.
module Spiremark.Engine.Eval
  ( View (..)
  , Ctx (..)
  , Env (..)
  , Ev
  , baseEdgeCore
  , objController
  , onField
  , canonSort
  , fieldOids
  , zoneCards
  , matchFilters
  , matchFilter
  , evalSel
  , evalPSel
  , evalDSel
  , evalAmt
  , evalCond
  , slotObj
  , runEv
  ) where

import Control.Monad (foldM)
import Control.Monad.State.Strict
import Data.Foldable (toList)
import Data.List (nub, sort)
import qualified Data.Sequence as Seq
import qualified Data.Set as Set

import Spiremark.Card.Types
import Spiremark.Engine.Types
import Spiremark.Random
import Spiremark.Types

-- | How to read characteristics that depend on the layer derivation.
data View = View
  { vCtl  :: Int -> Player
  , vEdge :: Int -> Int
  , vCore :: Int -> Int
  , vKw   :: Int -> [KwSpec]
  }

-- | What an ability evaluation is relative to.
data Ctx = Ctx
  { cxCtl   :: !Player
  , cxSrc   :: !Int
  , cxIt    :: Maybe Subject
  , cxThat  :: Maybe Int
  , cxSlots :: [Slot]
  , cxSpecs :: [TSpec]    -- ^ target specifications the slots were checked against
  }

-- | Evaluation environment.
data Env = Env
  { enG      :: G
  , enV      :: View
  , enC      :: Ctx
  , enRandom :: Bool     -- ^ whether @random-unit@ may consume randomness
  }

-- | Evaluation monad: threads the PRNG.
type Ev = State Rng

-- | Run an 'Ev' computation against the game's generator.
runEv :: Ev a -> G -> (a, G)
runEv m g =
  let (a, r) = runState m (gRng g)
   in (a, g { gRng = r })

onField :: Obj -> Bool
onField o = oZone o == ZnField

-- | Base edge and core: printed values plus charge counters (SPEC.md 6.2).
baseEdgeCore :: Obj -> (Int, Int)
baseEdgeCore o =
  let (e, c) = maybe (0, 0) id (cardBody (oCard o))
      n = fCounters (oF o)
   in (e + n, c + n)

-- | Current controller for Field objects, last controller otherwise.
objController :: View -> Obj -> Player
objController v o
  | onField o = vCtl v (oOid o)
  | otherwise = oLastCtl o

canonSort :: G -> [Int] -> [Int]
canonSort g = map snd . sort . map (\i -> let o = getObj i g in (oTs o, i))

-- | Field objects in canonical order.
fieldOids :: G -> [Int]
fieldOids g = map snd (Set.toAscList (gField g))

-- | Cards of a player's zone in zone order.
zoneCards :: G -> CardZone -> Player -> [Int]
zoneCards g z p =
  let ps = pst p g
   in toList $ case z of
        CZHand -> pHand ps
        CZAsh -> pAsh ps
        CZVault -> pVault ps
        CZRift -> pRift ps

scopePlayers :: Player -> Scope -> [Player]
scopePlayers c s = case s of
  Yours -> [c]
  Theirs -> [other c]
  AllScope -> [A, B]

-- | The object a target slot denotes, if it is an unremoved object target.
slotObj :: Ctx -> Int -> Maybe Int
slotObj cx n
  | n >= 1, n <= length (cxSlots cx) =
      case cxSlots cx !! (n - 1) of
        Slot (TgtObj o) False -> Just o
        _ -> Nothing
  | otherwise = Nothing

slotAt :: Ctx -> Int -> Maybe Slot
slotAt cx n
  | n >= 1, n <= length (cxSlots cx) = Just (cxSlots cx !! (n - 1))
  | otherwise = Nothing

-- ---------------------------------------------------------------------------
-- Filters

matchFilters :: Env -> Obj -> [Filter] -> Bool
matchFilters env o = all (matchFilter env o)

-- | Filters test base characteristics (SPEC.md 6.2).
matchFilter :: Env -> Obj -> Filter -> Bool
matchFilter env o f = case f of
  FKw k -> any (\(KwSpec k' _) -> k' == k) (cardKeywords c)
  FNoKw k -> not (any (\(KwSpec k' _) -> k' == k) (cardKeywords c))
  FTag t -> t `elem` cardTags c
  FType t -> cardType c == t
  FCost cm n -> compareBy cm (cardCost c) n
  FEdge cm n -> compareBy cm (fst (baseEdgeCore o)) n
  FCore cm n -> compareBy cm (snd (baseEdgeCore o)) n
  FWounded -> onField o && fWounds fs > 0
  FReady -> onField o && not (fExhausted fs)
  FExhausted -> onField o && fExhausted fs
  FSettling -> onField o && fSince fs >= gTurn (enG env)
  FAttacking -> onField o && fAttacking fs
  FBlocking -> onField o && fBlocking fs /= Nothing
  FMine -> scopeOwner env o == cxCtl (enC env)
  FEnemy -> scopeOwner env o /= cxCtl (enC env)
  FOther -> oOid o /= cxSrc (enC env)
  FNot f' -> not (matchFilter env o f')
  where
    c = oCard o
    fs = oF o

-- ---------------------------------------------------------------------------
-- Selectors

-- Controller used by scopes: Field objects use the current controller;
-- other zones compare the card's owner.
scopeOwner :: Env -> Obj -> Player
scopeOwner env o
  | onField o = vCtl (enV env) (oOid o)
  | otherwise = oOwner o

fieldMatching :: Env -> (Obj -> Bool) -> Scope -> [Filter] -> [Int]
fieldMatching env typeOk sc fs =
  [ oid
  | oid <- fieldOids g
  , let o = getObj oid g
  , typeOk o
  , scopeOk (scopeOwner env o)
  , matchFilters env o fs
  ]
  where
    g = enG env
    c = cxCtl (enC env)
    scopeOk p = case sc of
      Yours -> p == c
      Theirs -> p /= c
      AllScope -> True

-- | Evaluate an object selector; results are in canonical order.
evalSel :: Env -> Sel -> Ev [Int]
evalSel env sel = case sel of
  SelSelf -> return [cxSrc cx]
  SelIt -> return $ case cxIt cx of
    Just (SubObj o) -> [o]
    _ -> []
  SelThat -> return (maybe [] pure (cxThat cx))
  SelTarget n -> return (maybe [] pure (slotObj cx n))
  SelUnits sc fs -> return (fieldMatching env isUnit sc fs)
  SelRelics sc fs -> return (fieldMatching env isRelic sc fs)
  SelCards z sc fs -> return $ canonSort g
    [ oid
    | p <- scopePlayers c sc
    , oid <- zoneCards g z p
    , matchFilters env (getObj oid g) fs
    ]
  SelRandomUnit sc fs ->
    let cands = fieldMatching env isUnit sc fs
     in if null cands || not (enRandom env)
          then return []
          else do
            r <- get
            let (i, r') = below (length cands) r
            put r'
            return [cands !! i]
  where
    g = enG env
    cx = enC env
    c = cxCtl cx
    isUnit o = cardType (oCard o) == Unit
    isRelic o = cardType (oCard o) == Relic

-- | Evaluate a player selector; results are in A-before-B order.
evalPSel :: Env -> PSel -> Ev [Player]
evalPSel env ps = case ps of
  PYou -> return [c]
  PFoe -> return [other c]
  PBoth -> return [A, B]
  PTarget n -> return $ case slotAt cx n of
    Just (Slot (TgtPlayer p) _) -> [p]
    _ -> []
  POwnerOf (SelTarget n)
    | Just (Slot (TgtPlayer p) _) <- slotAt cx n -> return [p]
  POwnerOf s -> do
    os <- evalSel env s
    return (sort (nub [oOwner (getObj o g) | o <- os]))
  where
    cx = enC env
    c = cxCtl cx
    g = enG env

-- | Evaluate a damage selector to target tokens in ascending target-key order.
evalDSel :: Env -> DSel -> Ev [Target]
evalDSel env ds = case ds of
  DPlayers ps -> map TgtPlayer <$> evalPSel env ps
  DObjects (SelTarget n) -> return $ case slotAt (enC env) n of
    Just (Slot t@(TgtPlayer _) _) -> [t]
    Just (Slot t@(TgtObj _) False) -> [t]
    _ -> []
  DObjects s -> map TgtObj <$> evalSel env s

-- ---------------------------------------------------------------------------
-- Amounts and conditions

evalAmt :: Env -> Amt -> Ev Int
evalAmt env a = case a of
  AInt n -> return n
  ACount s -> length <$> evalSel env s
  AHand ps -> sizeSum pHand ps
  AAsh ps -> sizeSum pAsh ps
  AVault ps -> sizeSum pVault ps
  AEdge s -> sumOver (vEdge v) s
  ACore s -> sumOver (vCore v) s
  AWounds s -> sumOver (\o -> let ob = getObj o g in if onField ob then fWounds (oF ob) else 0) s
  where
    g = enG env
    v = enV env
    sizeSum f ps = do
      players <- evalPSel env ps
      return (sum [Seq.length (f (pst p g)) | p <- players])
    sumOver f s = do
      os <- evalSel env s
      return (sum (map f os))

evalCond :: Env -> Cond -> Ev Bool
evalCond env cnd = case cnd of
  CCount s cm n -> (\os -> compareBy cm (length os) n) <$> evalSel env s
  CSpire ps cm n -> sums (pSpire) ps cm n
  CHand ps cm n -> sums (Seq.length . pHand) ps cm n
  CAsh ps cm n -> sums (Seq.length . pAsh) ps cm n
  CVault ps cm n -> sums (Seq.length . pVault) ps cm n
  CEmber ps cm n -> sums pEmber ps cm n
  CMyTurn -> return (gActive g == cxCtl (enC env))
  CAnd cs -> allM cs
  COr cs -> anyM cs
  CNot c' -> not <$> evalCond env c'
  where
    g = enG env
    sums f ps cm n = do
      players <- evalPSel env ps
      return (compareBy cm (sum [f (pst p g) | p <- players]) n)
    allM = foldM (\acc c' -> if acc then evalCond env c' else return False) True
    anyM = foldM (\acc c' -> if acc then return True else evalCond env c') False
