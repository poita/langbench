{-# LANGUAGE BangPatterns #-}
-- |
-- Module      : Datalog.Eval
-- Description : Semi-naive bottom-up evaluation of stratified programs.
module Datalog.Eval
  ( evaluate
  ) where

import Control.Monad (forM, forM_, unless, when)
import Control.Monad.ST (ST, runST)
import Data.Array (listArray)
import Data.Array.Base (unsafeFreeze, unsafeRead, unsafeWrite)
import Data.Array.ST (newArray)
import Data.Array.Unboxed (UArray)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.STRef (readSTRef)

import Datalog.Internal.Plan
import Datalog.Internal.Relation
import Datalog.Model
import Datalog.Syntax

-- Resolved (runtime) plan ---------------------------------------------------

data Env s = Env
  { envLo :: !(Arr s)  -- ^ per predicate: first row of the current delta
  }

data RFilter s
  = RNeg !(Relation s) !(Arr s) [Source]
  | RCmp !CmpOp !Source !Source

-- | One join step: relation, predicate id, row range kind, optional index,
-- key columns, key sources, key scratch buffer, intra-atom equalities,
-- (column, slot) bindings and filters to apply afterwards.
data RStep s = RStep
  !(Relation s) !Int !Kind !(Maybe (Index s)) [Int] [Source] !(Arr s)
  [(Int, Int)] [(Int, Int)] [RFilter s]

-- | Slots, variable-free filters, steps, head relation, head scratch
-- buffer and head sources.
data RPlan s = RPlan !(Arr s) [RFilter s] [RStep s] !(Relation s) !(Arr s) [Source]

newArr :: Int -> ST s (Arr s)
newArr n = newArray (0, max 1 n - 1) 0

resolve :: M.Map Int (Relation s) -> Plan -> ST s (RPlan s)
resolve rels (Plan pre steps (hp, hsrcs) nslots) = do
  slots <- newArr nslots
  pre' <- mapM rfilter pre
  steps' <- mapM rstep steps
  hbuf <- newArr (length hsrcs)
  pure (RPlan slots pre' steps' (rels M.! hp) hbuf hsrcs)
  where
    rfilter (FNeg p ss) = do
      b <- newArr (length ss)
      pure (RNeg (rels M.! p) b ss)
    rfilter (FCmp op a b) = pure (RCmp op a b)
    rstep (Step p kind key eqs binds fs) = do
      let rel = rels M.! p
          cols = map fst key
      kb <- newArr (length key)
      ix <- if null key || kind == KDelta then pure Nothing else Just <$> addIndex rel cols
      fs' <- mapM rfilter fs
      pure (RStep rel p kind ix cols (map snd key) kb eqs binds fs')

-- Running a plan -----------------------------------------------------------

srcVal :: Arr s -> Source -> ST s Int
srcVal _ (SConst c) = pure c
srcVal slots (SSlot s) = unsafeRead slots s
{-# INLINE srcVal #-}

fillBuf :: Arr s -> Arr s -> [Source] -> ST s ()
fillBuf slots buf = go 0
  where
    go !_ [] = pure ()
    go !i (s : ss) = srcVal slots s >>= unsafeWrite buf i >> go (i + 1) ss

cmpHolds :: CmpOp -> Int -> Int -> Bool
cmpHolds op x y = case op of
  OpLt -> x < y
  OpLe -> x <= y
  OpGt -> x > y
  OpGe -> x >= y
  OpEq -> x == y
  OpNe -> x /= y

filtersHold :: Arr s -> [RFilter s] -> ST s Bool
filtersHold _ [] = pure True
filtersHold slots (f : fs) = do
  ok <- case f of
    RCmp op a b -> do
      x <- srcVal slots a
      y <- srcVal slots b
      pure (cmpHolds op x y)
    RNeg rel buf ss -> do
      fillBuf slots buf ss
      not <$> memberRow rel buf 0
  if ok then filtersHold slots fs else pure False

runPlan :: Env s -> RPlan s -> ST s ()
runPlan env (RPlan slots pre steps hrel hbuf hsrcs) = do
  ok <- filtersHold slots pre
  when ok (go steps)
  where
    go [] = do
      fillBuf slots hbuf hsrcs
      m <- memberRow hrel hbuf 0
      unless m (pushBuffer hrel hbuf 0)
    go (RStep rel p kind mix cols keySrc kb eqs binds fs : rest) = do
      dat <- readSTRef (relRows rel)
      size <- relSize rel
      lo <- unsafeRead (envLo env) p
      let ar = relArity rel
          (from, to) = case kind of
            KFull -> (0, size)
            KOld -> (0, lo)
            KDelta -> (lo, size)
          nkey = length cols
      fillBuf slots kb keySrc
      let keyOk !base = chk cols 0
            where
              chk [] _ = pure True
              chk (c : cs) !i = do
                a <- unsafeRead dat (base + c)
                b <- unsafeRead kb i
                if a == b then chk cs (i + 1) else pure False
          eqOk !base = and' eqs
            where
              and' [] = pure True
              and' ((c1, c2) : more) = do
                a <- unsafeRead dat (base + c1)
                b <- unsafeRead dat (base + c2)
                if a == b then and' more else pure False
          tryRow !r = do
            let base = r * ar
            k <- keyOk base
            when k $ do
              e <- eqOk base
              when e $ do
                forM_ binds $ \(c, s) -> unsafeRead dat (base + c) >>= unsafeWrite slots s
                f <- filtersHold slots fs
                when f (go rest)
      case mix of
        Nothing ->
          let loop !r = when (r < to) (tryRow r >> loop (r + 1)) in loop from
        Just ix -> do
          h <- hashSeq kb 0 nkey
          let walk !r = when (r >= 0) $ do
                when (r < to) (tryRow r)
                chainNext ix r >>= walk
          chainStart ix h >>= walk

-- Driver ---------------------------------------------------------------------

-- | Compute the perfect model. The component list must be in evaluation
-- order, as returned by 'Datalog.Analysis.stratify', and the program must
-- be safe.
evaluate :: Program -> [[Predicate]] -> Model
evaluate prog comps = runST $ do
  rels <- M.fromList <$> forM (M.toList predIds) (\(p, i) -> (,) i <$> newRelation (predArity p))
  lo <- newArr (M.size predIds)
  let env = Env lo
      compIds = [[predIds M.! p | p <- c, M.member p predIds] | c <- comps]
  -- compile everything first so all indexes exist before data arrives
  compiled <- forM compIds $ \cids -> do
    let cset = S.fromList cids
        isRec = (`S.member` cset)
        mine = [r | r <- irules, S.member (headPred r) cset]
        full = [planRule isRec r Nothing | r <- mine]
        variants =
          [ (headPred r, p, planRule isRec r (Just j))
          | r <- mine
          , (j, IPos (IAtom p _)) <- zip [0 ..] (irBody r)
          , isRec p
          ]
    rfull <- mapM (resolve rels) full
    rvars <- forM variants $ \(_, p, pl) -> (,) p <$> resolve rels pl
    pure (cids, rfull, rvars)
  -- facts
  forM_ ifacts $ \(IRule (IAtom p ts) _ _) -> do
    let rel = rels M.! p
    buf <- newArr (length ts)
    forM_ (zip [0 ..] ts) $ \(i, t) -> case t of
      IConst c -> unsafeWrite buf i c
      IVar _ -> pure ()
    pushBuffer rel buf 0
  forM_ (M.elems rels) flushBuffer
  -- strata
  forM_ compiled $ \(cids, rfull, rvars) -> do
    let crels = [rels M.! c | c <- cids]
        flushAll = do
          sizes <- forM (zip cids crels) $ \(c, r) -> do
            n <- relSize r
            unsafeWrite lo c n
            pure n
          mapM_ flushBuffer crels
          news <- forM (zip crels sizes) $ \(r, n) -> (\m -> m - n) <$> relSize r
          pure (sum news)
    mapM_ (runPlan env) rfull
    let rounds = do
          added <- flushAll
          when (added > 0) $ do
            forM_ rvars $ \(p, pl) -> do
              l <- unsafeRead lo p
              n <- relSize (rels M.! p)
              when (n > l) (runPlan env pl)
            rounds
    rounds
  frozen <- forM (M.toList predIds) $ \(p, i) -> do
    let rel = rels M.! i
    n <- relSize rel
    arr <- readSTRef (relRows rel) >>= unsafeFreeze
    pure (p, Rows (predArity p) n (arr :: UArray Int Int))
  pure (Model constArr constIds (M.fromList frozen))
  where
    rules = progRules prog
    allConsts = S.toAscList . S.fromList $
      [ c | Rule h b <- rules, a <- h : [x | l <- b, x <- litAtoms l], TConst c <- atomArgs a ]
        ++ [ c | Rule _ b <- rules, Cmp _ x y <- b, TConst c <- [x, y] ]
    litAtoms (Pos a) = [a]
    litAtoms (Neg a) = [a]
    litAtoms _ = []
    constIds = M.fromList (zip allConsts [0 ..])
    constArr = listArray (0, length allConsts - 1) allConsts
    predIds = M.fromList (zip (S.toAscList (S.fromList allPreds)) [0 ..])
    allPreds =
      [ atomPredicate a | Rule h b <- rules, a <- h : concatMap litAtoms b ]
        ++ concat comps
        ++ map atomPredicate (progQueries prog)
    irules0 = map (internRule constIds predIds) rules
    ifacts = [r | r <- irules0, null (irBody r)]
    irules = [r | r <- irules0, not (null (irBody r))]
    headPred r = let IAtom p _ = irHead r in p
