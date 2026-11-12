-- |
-- Module      : Spiremark.Engine.Derive
-- Description : Whole-board derivation of current characteristics (SPEC.md 14).
--
-- 'derive' computes, in one pass over the Field and the continuous-effect
-- records, every object's current controller, edge, core and keywords, plus
-- the evaluation of each aura record.  The result is cached in the game state
-- ('gDerived') and dropped whenever the state changes.
module Spiremark.Engine.Derive
  ( derive
  , getDerived
  , viewOf
  , getView
  , invalidate
  , currentKeywords
  , hasKw
  , platingTotal
  , isStripped
  ) where

import Control.Monad.State.Strict
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.Bits ((.|.))
import Data.List (sortOn)
import Data.Maybe (fromMaybe)

import Spiremark.Card.Types
import Spiremark.Engine.Eval
import Spiremark.Engine.Types
import Spiremark.Random (mkRng)
import Spiremark.Types

-- | Drop the cached derivation.
invalidate :: G -> G
invalidate g = g { gDerived = Nothing }

-- | The derivation, computed on demand and cached.
getDerived :: Eng Derived
getDerived = do
  g <- get
  case gDerived g of
    Just d -> return d
    Nothing -> do
      let d = derive g
      put g { gDerived = Just d }
      return d

-- | A 'View' of current characteristics.
viewOf :: G -> Derived -> View
viewOf g d = View
  { vCtl = \o -> case IM.lookup o (dCtl d) of
      Just p -> p
      Nothing -> maybe A oOwner (lookupObj o g)
  , vEdge = \o -> case IM.lookup o (dStats d) of
      Just (e, _) -> e
      Nothing -> printedStat fst o
  , vCore = \o -> case IM.lookup o (dStats d) of
      Just (_, c) -> c
      Nothing -> printedStat snd o
  , vKw = \o -> case IM.lookup o (dKw d) of
      Just ks -> ks
      Nothing -> maybe [] (cardKeywords . oCard) (lookupObj o g)
  }
  where
    printedStat f o = maybe 0 (f . fromMaybe (0, 0) . cardBody . oCard) (lookupObj o g)

getView :: Eng View
getView = do
  d <- getDerived
  g <- get
  return (viewOf g d)

-- | Current keywords of an object (printed ones off the Field).
currentKeywords :: View -> Int -> [KwSpec]
currentKeywords = vKw

-- | Whether the object currently has a keyword.
hasKw :: View -> Int -> Keyword -> Bool
hasKw v o k = any (\(KwSpec k' _) -> k' == k) (vKw v o)

-- | Sum of all @plating@ values among current keywords.
platingTotal :: View -> Int -> Int
platingTotal v o = sum [n | KwSpec Plating n <- vKw v o]

-- | Whether the object is stripped (abilities removed) by the derivation.
isStripped :: Derived -> Int -> Bool
isStripped d o = IS.member o (dStripped d)

-- One contribution of an aura static.
data Contrib = Contrib
  { cbDesc    :: String
  , cbKind    :: Maybe DKind
  , cbObjs    :: [Int]
  , cbCheaper :: Maybe (Int, [CardFilter])
  , cbActive  :: Bool
  }

-- | Derive the whole board (SPEC.md 14.3).
derive :: G -> Derived
derive g = Derived
  { dCtl = ctlMap
  , dStripped = stripped
  , dStats = stats
  , dKw = kws
  , dAuras = auraEvals
  , dCheaper = cheapers
  , dDeps = foldl' (.|.) 0 [ staticsDeps (abStatics ab) | r <- recs, RAura ab <- [rBody r] ]
  }
  where
    fieldList = fieldOids g
    recs = sortOn (\r -> (rTs r, rEid r)) (IM.elems (gRecs g))
    onF o = maybe False onField (lookupObj o g)

    -- Layer 1
    ctl0 = IM.fromList [(o, fCtl (oF (getObj o g))) | o <- fieldList]
    ctlMap = foldl' applyControl ctl0 recs
    applyControl m r = case rBody r of
      RDiscrete (DControl p) objs ->
        foldl' (\m' o -> if onF o then IM.insert o p m' else m') m objs
      _ -> m

    -- Step 2: stripped objects
    stripped = IS.fromList
      [ o | r <- recs, RDiscrete DStrip objs <- [rBody r], o <- objs, onF o ]

    -- Step 3: aura records, using layer-1 controllers and base stats
    baseView = View
      { vCtl = \o -> IM.findWithDefault A o ctlMap
      , vEdge = \o -> fst (baseEdgeCore (getObj o g))
      , vCore = \o -> snd (baseEdgeCore (getObj o g))
      , vKw = \_ -> []
      }
    auraList =
      [ (r, c, contribs)
      | r <- recs
      , RAura ab <- [rBody r]
      , let src = rSrc r
      , onF src
      , let c = IM.findWithDefault A src ctlMap
            env = Env g baseView (Ctx c src Nothing Nothing [] []) False
            live = not (IS.member src stripped)
            contribs = concatMap (evalStatic env live) (abStatics ab)
      ]
    auraContribs = IM.fromList [(rEid r, cs) | (r, _, cs) <- auraList]
    auraEvals = IM.fromList
      [ (rEid r, AuraEval { aeActive = active, aeDesc = desc, aeObjs = objs, aeCtl = c })
      | (r, c, contribs) <- auraList
      , let (active, desc, objs) = case contribs of
              [] -> (False, "", [])
              (cb : _) -> (cbActive cb, cbDesc cb, if cbActive cb then cbObjs cb else [])
      ]
    cheapers =
      [ (c, n, fs)
      | (_, c, contribs) <- auraList
      , cb <- contribs
      , cbActive cb
      , Just (n, fs) <- [cbCheaper cb]
      ]

    -- All active discrete and aura effects, in (timestamp, eid) order.
    effects :: [(DKind, [Int])]
    effects = concat
      [ case rBody r of
          RDiscrete k objs -> [(k, filter onF objs)]
          RAura _ -> [ (k, os)
                     | Just contribs <- [IM.lookup (rEid r) auraContribs]
                     , cb <- contribs, cbActive cb, Just k <- [cbKind cb]
                     , let os = filter onF (cbObjs cb) ]
      | r <- recs
      ]

    -- Layer 2
    kw0 = IM.fromList [(o, cardKeywords (oCard (getObj o g))) | o <- fieldList]
    kws = foldl' applyKw kw0 effects
    applyKw m (k, objs) = case k of
      DGrant spec -> foldl' (\m' o -> IM.adjust (++ [spec]) o m') m objs
      DStrip -> foldl' (\m' o -> IM.insert o [] m') m objs
      _ -> m

    -- Layers 3-6
    st0 = IM.fromList [(o, fromMaybe (0, 0) (cardBody (oCard (getObj o g)))) | o <- fieldList]
    l3 = foldl' (\m (k, objs) -> case k of
                    DSetbody e c -> foldl' (\m' o -> IM.insert o (e, c) m') m objs
                    _ -> m) st0 effects
    l4 = foldl' (\m (k, objs) -> case k of
                    DModify e c -> foldl' (\m' o -> IM.adjust (\(x, y) -> (x + e, y + c)) o m') m objs
                    _ -> m) l3 effects
    l5 = IM.mapWithKey (\o (x, y) -> let n = fCounters (oF (getObj o g)) in (x + n, y + n)) l4
    stats = foldl' (\m (k, objs) -> case k of
                      DSwap -> foldl' (\m' o -> IM.adjust (\(x, y) -> (y, x)) o m') m objs
                      _ -> m) l5 effects

-- | Evaluate one static; @live@ says whether enclosing conditions hold and the
-- source is not stripped.
evalStatic :: Env -> Bool -> Static -> [Contrib]
evalStatic env live st = case st of
  StModify a b s -> one live (\e c -> "modify " ++ show e ++ " " ++ show c) a b s DModify
  StSetbody a b s -> one live (\e c -> "setbody " ++ show e ++ " " ++ show c) a b s DSetbody
  StSwapstats s ->
    let os = sel s
     in [Contrib "swapstats" (Just DSwap) (gate os) Nothing live]
  StGrant spec s ->
    let os = sel s
     in [Contrib ("grant " ++ renderKw spec) (Just (DGrant spec)) (gate os) Nothing live]
  StCheaper n fs -> [Contrib ("cheaper " ++ show n) Nothing [] (Just (n, fs)) live]
  StWhen c sts ->
    let ok = evalNoRng (evalCond env c)
     in concatMap (evalStatic env (live && ok)) sts
  where
    sel s = filter (maybe False onField . flip lookupObj (enG env)) (evalNoRng (evalSel env s))
    gate os = if live then os else []
    one lv fmt a b s mk =
      let e = evalNoRng (evalAmt env a)
          c = evalNoRng (evalAmt env b)
          os = sel s
       in [Contrib (fmt e c) (Just (mk e c)) (if lv then os else []) Nothing lv]

evalNoRng :: Ev a -> a
evalNoRng m = evalState m (mkRng 1)

-- State classes (bit masks) that a derivation can read besides the structure
-- of the Field and the records: zone contents, player totals, per-object
-- Field state (wounds, exhaustion, combat status, ...).
staticsDeps :: [Static] -> Int
staticsDeps = foldl' (.|.) 0 . map one
  where
    one st = case st of
      StModify a b s -> amtDeps a .|. amtDeps b .|. selDeps s
      StSetbody a b s -> amtDeps a .|. amtDeps b .|. selDeps s
      StSwapstats s -> selDeps s
      StGrant _ s -> selDeps s
      StCheaper _ _ -> 0
      StWhen c sts -> condDeps c .|. staticsDeps sts

selDeps :: Sel -> Int
selDeps s = case s of
  SelUnits _ fs -> filtersDeps fs
  SelRelics _ fs -> filtersDeps fs
  SelCards _ _ fs -> 1 .|. 4 .|. filtersDeps fs
  SelRandomUnit _ fs -> filtersDeps fs
  _ -> 0

filtersDeps :: [Filter] -> Int
filtersDeps = foldl' (.|.) 0 . map f
  where
    f x = case x of
      FWounded -> 4; FReady -> 4; FExhausted -> 4; FSettling -> 4
      FAttacking -> 4; FBlocking -> 4
      FNot y -> f y
      _ -> 0

psDeps :: PSel -> Int
psDeps (POwnerOf s) = selDeps s
psDeps _ = 0

amtDeps :: Amt -> Int
amtDeps a = case a of
  AInt _ -> 0
  ACount s -> selDeps s
  AHand p -> 1 .|. psDeps p
  AAsh p -> 1 .|. psDeps p
  AVault p -> 1 .|. psDeps p
  AEdge s -> selDeps s
  ACore s -> selDeps s
  AWounds s -> 4 .|. selDeps s

condDeps :: Cond -> Int
condDeps c = case c of
  CCount s _ _ -> selDeps s
  CSpire p _ _ -> 2 .|. psDeps p
  CEmber p _ _ -> 2 .|. psDeps p
  CHand p _ _ -> 1 .|. psDeps p
  CAsh p _ _ -> 1 .|. psDeps p
  CVault p _ _ -> 1 .|. psDeps p
  CMyTurn -> 0
  CAnd cs -> foldl' (.|.) 0 (map condDeps cs)
  COr cs -> foldl' (.|.) 0 (map condDeps cs)
  CNot x -> condDeps x
