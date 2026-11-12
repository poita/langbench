{-# LANGUAGE BangPatterns #-}
-- |
-- Module      : Sat.Solver
-- Description : A MiniSat-style conflict-driven clause-learning solver.
--
-- The solver implements
--
-- * two-watched-literal unit propagation (with blocking literals);
-- * first-UIP conflict analysis with local (non-recursive) clause
--   minimisation;
-- * VSIDS branching (activities bumped per conflict, geometric decay) over an
--   indexed binary heap, with phase saving (initial phase: false);
-- * Luby restarts (restart @i@ allows @100 * luby 2 i@ conflicts);
-- * periodic deletion of the less active half of the learnt clauses, which
--   always keeps binary learnt clauses.
--
-- Most users want the pure 'solve'.  The incremental-style interface
-- ('newSolver', 'addClause', 'solveSolver') runs in 'ST' and lets a formula
-- be built clause by clause; a solver can be run to completion once.
module Sat.Solver
  ( -- * Pure interface
    solve
    -- * Imperative interface
  , Solver
  , newSolver
  , addClause
  , solveSolver
  ) where

import Control.Monad (forM_, when)
import Control.Monad.ST (ST, runST)
import Data.Array.Base (getNumElements, newListArray, unsafeFreeze, unsafeRead, unsafeWrite)
import Data.Array.ST (STArray, STUArray, newArray)
import Data.Bits (shiftR, xor)
import Data.List (sort, sortBy)
import Data.Ord (comparing)

import Sat.Internal.Heap (Heap)
import qualified Sat.Internal.Heap as H
import Sat.Internal.Vec
import Sat.Types

------------------------------------------------------------------------
-- Representation
------------------------------------------------------------------------

-- Internal literals: variable v (1-based) gives 2v (positive) and 2v+1
-- (negative), so negation is xor 1 and the variable is a right shift.
type ILit = Int

toILit :: Lit -> ILit
toILit d | d > 0 = 2 * d
         | otherwise = 2 * negate d + 1
{-# INLINE toILit #-}

neg :: ILit -> ILit
neg l = l `xor` 1
{-# INLINE neg #-}

var :: ILit -> Int
var l = l `shiftR` 1
{-# INLINE var #-}

-- Literal values: 0 unassigned, 1 true, -1 false.
valTrue, valFalse :: Int
valTrue = 1
valFalse = -1

noReason :: Int
noReason = -1

-- Clause flag bits.
flagLearnt, flagDeleted :: Int
flagLearnt = 1
flagDeleted = 2

-- Scalar (Int) state slots.
scQHead, scOk, scConflicts, scStored :: Int
scQHead = 0       -- next trail position to propagate
scOk = 1          -- 0 once the formula is known unsatisfiable
scConflicts = 2   -- conflicts since the last restart
scStored = 3      -- number of stored (non-unit) input clauses

-- Scalar (Double) state slots.
dbVarInc, dbClaInc, dbMaxLearnts :: Int
dbVarInc = 0
dbClaInc = 1
dbMaxLearnts = 2

-- | Mutable solver state.
data Solver s = Solver
  { sNumVars   :: !Int
  , sVals      :: !(STUArray s Int Int)      -- per literal
  , sLevel     :: !(STUArray s Int Int)      -- per variable
  , sReason    :: !(STUArray s Int Int)      -- per variable: clause id or noReason
  , sPhase     :: !(STUArray s Int Int)      -- per variable: saved value (0/1)
  , sSeen      :: !(STUArray s Int Int)      -- per variable, scratch for analysis
  , sAct       :: !(STUArray s Int Double)   -- per variable activity
  , sHeap      :: !(Heap s)
  , sTrail     :: !(IntVec s)
  , sTrailLim  :: !(IntVec s)                -- trail size at each decision level
  , sWatches   :: !(STArray s Int (IntVec s)) -- per literal: (clause, blocker) pairs
  , sClauses   :: !(Vec (STArray s) s (STUArray s Int Int))
  , sClAct     :: !(Vec (STUArray s) s Double)
  , sClFlags   :: !(IntVec s)
  , sFree      :: !(IntVec s)                -- recycled clause ids
  , sLearnts   :: !(IntVec s)                -- ids of live learnt clauses
  , sLearntBuf :: !(IntVec s)                -- scratch: clause under analysis
  , sToClear   :: !(IntVec s)                -- scratch: seen flags to reset
  , sScal      :: !(STUArray s Int Int)
  , sDbl       :: !(STUArray s Int Double)
  }

-- | Create a solver for variables @1..n@ with no clauses.
newSolver :: Int -> ST s (Solver s)
newSolver n = do
  vals <- newArray (0, 2 * n + 1) 0
  lvl <- newArray (0, n) 0
  rsn <- newArray (0, n) noReason
  ph <- newArray (0, n) 0
  seen <- newArray (0, n) 0
  act <- newArray (0, n) 0
  heap <- H.newHeap (n + 1) act
  forM_ [1 .. n] (H.insert heap)
  trail <- newVec (n + 1) 0
  lim <- newVec 16 0
  emptyW <- newVec 1 0
  ws <- newArray (0, 2 * n + 1) emptyW
  forM_ [0 .. 2 * n + 1] $ \i -> newVec 4 0 >>= unsafeWrite ws i
  noClause <- newArray (0, 0) 0
  cls <- newVec 64 noClause
  cact <- newVec 64 0
  cfl <- newVec 64 0
  free <- newVec 16 0
  learnts <- newVec 64 0
  lbuf <- newVec 16 0
  tclr <- newVec 16 0
  scal <- newArray (0, 7) 0
  unsafeWrite scal scOk 1
  dbl <- newArray (0, 7) 0
  unsafeWrite dbl dbVarInc 1
  unsafeWrite dbl dbClaInc 1
  return Solver
    { sNumVars = n, sVals = vals, sLevel = lvl, sReason = rsn, sPhase = ph
    , sSeen = seen, sAct = act, sHeap = heap, sTrail = trail, sTrailLim = lim
    , sWatches = ws, sClauses = cls, sClAct = cact, sClFlags = cfl
    , sFree = free, sLearnts = learnts, sLearntBuf = lbuf, sToClear = tclr
    , sScal = scal, sDbl = dbl }

------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------

getS :: Solver s -> Int -> ST s Int
getS s = unsafeRead (sScal s)
{-# INLINE getS #-}

putS :: Solver s -> Int -> Int -> ST s ()
putS s = unsafeWrite (sScal s)
{-# INLINE putS #-}

getD :: Solver s -> Int -> ST s Double
getD s = unsafeRead (sDbl s)
{-# INLINE getD #-}

putD :: Solver s -> Int -> Double -> ST s ()
putD s = unsafeWrite (sDbl s)
{-# INLINE putD #-}

litVal :: Solver s -> ILit -> ST s Int
litVal s = unsafeRead (sVals s)
{-# INLINE litVal #-}

decisionLevel :: Solver s -> ST s Int
decisionLevel s = vsize (sTrailLim s)
{-# INLINE decisionLevel #-}

-- Assign a literal true with the given reason at the current level.
enqueue :: Solver s -> ILit -> Int -> ST s ()
enqueue s l r = do
  unsafeWrite (sVals s) l valTrue
  unsafeWrite (sVals s) (neg l) valFalse
  lv <- decisionLevel s
  unsafeWrite (sLevel s) (var l) lv
  unsafeWrite (sReason s) (var l) r
  vpush (sTrail s) l

watchPush :: Solver s -> ILit -> Int -> ILit -> ST s ()
watchPush s l cid blocker = do
  w <- unsafeRead (sWatches s) l
  vpush w cid
  vpush w blocker
{-# INLINE watchPush #-}

------------------------------------------------------------------------
-- Clause database
------------------------------------------------------------------------

-- Store a clause (at least two literals) and watch its first two literals.
allocClause :: Solver s -> [ILit] -> Bool -> ST s Int
allocClause s lits learnt = do
  arr <- newListArray (0, length lits - 1) lits
  nfree <- vsize (sFree s)
  cid <- if nfree > 0
    then vpop (sFree s)
    else do
      n <- vsize (sClauses s)
      vpush (sClauses s) arr
      vpush (sClAct s) 0
      vpush (sClFlags s) 0
      return n
  vset (sClauses s) cid arr
  vset (sClAct s) cid 0
  vset (sClFlags s) cid (if learnt then flagLearnt else 0)
  l0 <- unsafeRead arr 0
  l1 <- unsafeRead arr 1
  watchPush s l0 cid l1
  watchPush s l1 cid l0
  return cid

-- | Add a clause (DIMACS literals) at the root level.  Duplicate literals,
-- tautologies, root-satisfied clauses and root-false literals are simplified
-- away; unit clauses are assigned and propagated immediately.  Returns
-- 'False' if the formula is now known to be unsatisfiable.  Literals must
-- refer to variables @1..n@ of the solver.
addClause :: Solver s -> [Lit] -> ST s Bool
addClause s dimacs = do
  ok <- getS s scOk
  if ok == 0 then return False else do
    let sorted = dedupe (sort (map toILit dimacs))
    if isTautology sorted then return True else do
      vals <- mapM (litVal s) sorted
      if valTrue `elem` vals then return True else do
        let lits = [l | (l, v) <- zip sorted vals, v /= valFalse]
        case lits of
          [] -> putS s scOk 0 >> return False
          [l] -> do
            enqueue s l noReason
            confl <- propagate s
            if confl >= 0 then putS s scOk 0 >> return False else return True
          _ -> do
            _ <- allocClause s lits False
            st <- getS s scStored
            putS s scStored (st + 1)
            return True
  where
    dedupe (a : b : r) | a == b = dedupe (b : r)
                       | otherwise = a : dedupe (b : r)
    dedupe r = r
    -- after sorting, l and neg l (2v, 2v+1) are adjacent
    isTautology (a : b : r) = (even a && b == a + 1) || isTautology (b : r)
    isTautology _ = False

------------------------------------------------------------------------
-- Propagation
------------------------------------------------------------------------

-- Run unit propagation to fixpoint.  Returns the id of a conflicting clause,
-- or -1 if there is none.
propagate :: Solver s -> ST s Int
propagate s = loop
  where
    loop = do
      qh <- getS s scQHead
      tsz <- vsize (sTrail s)
      if qh >= tsz
        then return (-1)
        else do
          p <- vget (sTrail s) qh
          putS s scQHead (qh + 1)
          r <- propagateLit s (neg p)
          if r >= 0 then putS s scQHead tsz >> return r else loop

-- Visit every clause watching the literal @fl@, which has just become false.
propagateLit :: Solver s -> ILit -> ST s Int
propagateLit s fl = do
  w <- unsafeRead (sWatches s) fl
  n <- vsize w
  arrW <- vdata w
  let go !i !j
        | i >= n = vshrink w j >> return (-1)
        | otherwise = do
            cid <- unsafeRead arrW i
            blk <- unsafeRead arrW (i + 1)
            bv <- litVal s blk
            if bv == valTrue
              then keep i j cid blk
              else do
                lits <- vget (sClauses s) cid
                l0 <- unsafeRead lits 0
                -- make sure the false literal is at index 1
                first <- if l0 == fl
                  then do
                    l1 <- unsafeRead lits 1
                    unsafeWrite lits 0 l1
                    unsafeWrite lits 1 fl
                    return l1
                  else return l0
                fv <- litVal s first
                if fv == valTrue
                  then keep i j cid first
                  else do
                    sz <- getNumElements lits
                    let findNew !k
                          | k >= sz = return (-1)
                          | otherwise = do
                              lk <- unsafeRead lits k
                              v <- litVal s lk
                              if v /= valFalse then return k else findNew (k + 1)
                    k <- findNew 2
                    if k >= 0
                      then do
                        lk <- unsafeRead lits k
                        unsafeWrite lits 1 lk
                        unsafeWrite lits k fl
                        watchPush s lk cid first
                        go (i + 2) j
                      else do
                        unsafeWrite arrW j cid
                        unsafeWrite arrW (j + 1) first
                        if fv == valFalse
                          then do
                            -- conflict: keep the remaining watchers
                            let copy !a !b
                                  | a >= n = return b
                                  | otherwise = do
                                      unsafeRead arrW a >>= unsafeWrite arrW b
                                      copy (a + 1) (b + 1)
                            j' <- copy (i + 2) (j + 2)
                            vshrink w j'
                            return cid
                          else do
                            enqueue s first cid
                            go (i + 2) (j + 2)
      keep i j cid blocker = do
        unsafeWrite arrW j cid
        unsafeWrite arrW (j + 1) blocker
        go (i + 2) (j + 2)
  go 0 0

------------------------------------------------------------------------
-- Activities
------------------------------------------------------------------------

bumpVar :: Solver s -> Int -> ST s ()
bumpVar s v = do
  inc <- getD s dbVarInc
  a <- unsafeRead (sAct s) v
  let a' = a + inc
  unsafeWrite (sAct s) v a'
  when (a' > 1e100) $ do
    forM_ [1 .. sNumVars s] $ \u ->
      unsafeRead (sAct s) u >>= unsafeWrite (sAct s) u . (* 1e-100)
    putD s dbVarInc (inc * 1e-100)
  H.increased (sHeap s) v

bumpClause :: Solver s -> Int -> ST s ()
bumpClause s cid = do
  inc <- getD s dbClaInc
  a <- vget (sClAct s) cid
  let a' = a + inc
  vset (sClAct s) cid a'
  when (a' > 1e20) $ do
    n <- vsize (sLearnts s)
    forM_ [0 .. n - 1] $ \i -> do
      c <- vget (sLearnts s) i
      vget (sClAct s) c >>= vset (sClAct s) c . (* 1e-20)
    putD s dbClaInc (inc * 1e-20)

decayActivities :: Solver s -> ST s ()
decayActivities s = do
  getD s dbVarInc >>= putD s dbVarInc . (/ 0.95)
  getD s dbClaInc >>= putD s dbClaInc . (/ 0.999)

------------------------------------------------------------------------
-- Conflict analysis
------------------------------------------------------------------------

-- Analyse a conflict (at decision level > 0).  Leaves the learnt clause in
-- 'sLearntBuf' with the asserting literal first and, if longer than one, a
-- literal of the backjump level second.  Returns the backjump level.
analyze :: Solver s -> Int -> ST s Int
analyze s confl0 = do
  let buf = sLearntBuf s
      toClear = sToClear s
  vclear buf
  vclear toClear
  vpush buf 0                       -- placeholder for the asserting literal
  dl <- decisionLevel s
  tsz <- vsize (sTrail s)
  let -- Fold the literals of a clause into the analysis; returns the number
      -- of new current-level literals.
      absorb !cid !from = do
        flags <- vget (sClFlags s) cid
        when (flags == flagLearnt) (bumpClause s cid)
        lits <- vget (sClauses s) cid
        sz <- getNumElements lits
        let lp !k !cnt
              | k >= sz = return cnt
              | otherwise = do
                  q <- unsafeRead lits k
                  let v = var q
                  sn <- unsafeRead (sSeen s) v
                  lv <- unsafeRead (sLevel s) v
                  if sn == 0 && lv > 0
                    then do
                      bumpVar s v
                      unsafeWrite (sSeen s) v 1
                      vpush toClear v
                      if lv >= dl
                        then lp (k + 1) (cnt + 1)
                        else vpush buf q >> lp (k + 1) cnt
                    else lp (k + 1) cnt
        lp from (0 :: Int)
      -- Walk the trail backwards to the next marked literal.
      step !confl !from !pathC !idx = do
        c <- absorb confl from
        let pathC' = pathC + c
            findSeen !i = do
              p <- vget (sTrail s) i
              sn <- unsafeRead (sSeen s) (var p)
              if sn /= 0 then return (p, i) else findSeen (i - 1)
        (p, i) <- findSeen idx
        let v = var p
        unsafeWrite (sSeen s) v 0
        if pathC' - 1 <= 0
          then return p
          else do
            r <- unsafeRead (sReason s) v
            step r 1 (pathC' - 1) (i - 1)
  p <- step confl0 0 0 (tsz - 1)
  vset buf 0 (neg p)
  -- Local minimisation: drop literals whose reason is covered by the clause.
  n <- vsize buf
  let minim !i !j
        | i >= n = return j
        | otherwise = do
            q <- vget buf i
            r <- unsafeRead (sReason s) (var q)
            redundant <- if r == noReason then return False else do
              lits <- vget (sClauses s) r
              sz <- getNumElements lits
              let chk !k
                    | k >= sz = return True
                    | otherwise = do
                        x <- unsafeRead lits k
                        sn <- unsafeRead (sSeen s) (var x)
                        lv <- unsafeRead (sLevel s) (var x)
                        if sn == 0 && lv > 0 then return False else chk (k + 1)
              chk 1
            if redundant then minim (i + 1) j else vset buf j q >> minim (i + 1) (j + 1)
  n' <- minim 1 1
  vshrink buf n'
  -- Reset the seen flags.
  nc <- vsize toClear
  forM_ [0 .. nc - 1] $ \i -> vget toClear i >>= \v -> unsafeWrite (sSeen s) v 0
  -- Backjump level, with its literal moved to index 1.
  if n' == 1
    then return 0
    else do
      let best !i !bi !bl
            | i >= n' = return (bi, bl)
            | otherwise = do
                q <- vget buf i
                lv <- unsafeRead (sLevel s) (var q)
                if lv > bl then best (i + 1) i lv else best (i + 1) bi bl
      (bi, bl) <- best 1 1 (-1)
      a <- vget buf 1
      b <- vget buf bi
      vset buf 1 b
      vset buf bi a
      return bl

------------------------------------------------------------------------
-- Backtracking and decisions
------------------------------------------------------------------------

-- Undo all assignments above the given decision level.
cancelUntil :: Solver s -> Int -> ST s ()
cancelUntil s lvl = do
  dl <- decisionLevel s
  when (dl > lvl) $ do
    start <- vget (sTrailLim s) lvl
    tsz <- vsize (sTrail s)
    let undo !i
          | i < start = return ()
          | otherwise = do
              l <- vget (sTrail s) i
              let v = var l
              unsafeWrite (sVals s) l 0
              unsafeWrite (sVals s) (neg l) 0
              unsafeWrite (sPhase s) v (if even l then 1 else 0)
              H.insert (sHeap s) v
              undo (i - 1)
    undo (tsz - 1)
    vshrink (sTrail s) start
    vshrink (sTrailLim s) lvl
    putS s scQHead start

-- Highest-activity unassigned variable, if any.
pickBranchVar :: Solver s -> ST s (Maybe Int)
pickBranchVar s = do
  mv <- H.removeMax (sHeap s)
  case mv of
    Nothing -> return Nothing
    Just v -> do
      x <- litVal s (2 * v)
      if x == 0 then return (Just v) else pickBranchVar s

------------------------------------------------------------------------
-- Learnt clause reduction
------------------------------------------------------------------------

-- Delete the less active half of the learnt clauses (keeping binary ones).
-- Must be called at decision level 0.
reduceDB :: Solver s -> ST s ()
reduceDB s = do
  n <- vsize (sLearnts s)
  ids <- mapM (vget (sLearnts s)) [0 .. n - 1]
  keyed <- mapM (\c -> do a <- vget (sClAct s) c; return (a, c)) ids
  let sorted = map snd (sortBy (comparing fst) keyed)
      (cand, rest) = splitAt (n `div` 2) sorted
  -- level-0 reasons are never consulted; clear them so ids can be recycled
  tsz <- vsize (sTrail s)
  forM_ [0 .. tsz - 1] $ \i -> vget (sTrail s) i >>= \l -> unsafeWrite (sReason s) (var l) noReason
  keptBinary <- fmap concat $ mapM (\c -> do
      lits <- vget (sClauses s) c
      sz <- getNumElements lits
      if sz <= 2
        then return [c]
        else do
          vset (sClFlags s) c (flagLearnt + flagDeleted)
          return []) cand
  -- drop watchers of deleted clauses
  forM_ [0 .. 2 * sNumVars s + 1] $ \l -> do
    w <- unsafeRead (sWatches s) l
    m <- vsize w
    arr <- vdata w
    let sweep !i !j
          | i >= m = vshrink w j
          | otherwise = do
              c <- unsafeRead arr i
              b <- unsafeRead arr (i + 1)
              f <- vget (sClFlags s) c
              if f >= flagDeleted
                then sweep (i + 2) j
                else unsafeWrite arr j c >> unsafeWrite arr (j + 1) b >> sweep (i + 2) (j + 2)
    sweep 0 0
  noClause <- newArray (0, 0) 0
  forM_ cand $ \c -> do
    f <- vget (sClFlags s) c
    when (f >= flagDeleted) $ do
      vset (sClauses s) c noClause
      vpush (sFree s) c
  vclear (sLearnts s)
  forM_ (keptBinary ++ rest) (vpush (sLearnts s))

------------------------------------------------------------------------
-- Search
------------------------------------------------------------------------

data Outcome = Restart | Sat | Unsat deriving Eq

-- The Luby sequence 1 1 2 1 1 2 4 ..., scaled by @y^k@; index starts at 0.
luby :: Int -> Int -> Int
luby y x0 = y ^ seqn
  where
    (size0, seq0) = grow 1 0
    grow sz sq | sz < x0 + 1 = grow (2 * sz + 1) (sq + 1)
               | otherwise = (sz, sq :: Int)
    (_, seqn) = shrink size0 seq0 x0
    shrink sz sq x
      | sz - 1 /= x = let sz' = (sz - 1) `shiftR` 1 in shrink sz' (sq - 1) (x `mod` sz')
      | otherwise = (sz, sq)

-- Search until a model, a refutation, or the conflict budget is exhausted.
search :: Solver s -> Int -> ST s Outcome
search s budget = putS s scConflicts 0 >> loop
  where
    loop = do
      confl <- propagate s
      if confl >= 0 then conflict confl else noConflict
    conflict confl = do
      cs <- getS s scConflicts
      putS s scConflicts (cs + 1)
      dl <- decisionLevel s
      if dl == 0
        then putS s scOk 0 >> return Unsat
        else do
          bt <- analyze s confl
          cancelUntil s bt
          n <- vsize (sLearntBuf s)
          if n == 1
            then vget (sLearntBuf s) 0 >>= \l -> enqueue s l noReason
            else do
              lits <- mapM (vget (sLearntBuf s)) [0 .. n - 1]
              cid <- allocClause s lits True
              vpush (sLearnts s) cid
              bumpClause s cid
              vget (sLearntBuf s) 0 >>= \l0 -> enqueue s l0 cid
          decayActivities s
          loop
    noConflict = do
      cs <- getS s scConflicts
      if cs >= budget
        then cancelUntil s 0 >> return Restart
        else do
          mv <- pickBranchVar s
          case mv of
            Nothing -> return Sat
            Just v -> do
              ph <- unsafeRead (sPhase s) v
              tsz <- vsize (sTrail s)
              vpush (sTrailLim s) tsz
              enqueue s (if ph == 1 then 2 * v else 2 * v + 1) noReason
              loop

-- | Decide the clauses added so far.  Intended to be called once.
solveSolver :: Solver s -> ST s Result
solveSolver s = do
  ok <- getS s scOk
  if ok == 0 then return Unsatisfiable else do
    stored <- getS s scStored
    putD s dbMaxLearnts (fromIntegral (max (stored `div` 3) 2000))
    run 0
  where
    run !i = do
      nl <- vsize (sLearnts s)
      ml <- getD s dbMaxLearnts
      when (fromIntegral nl >= ml) $ do
        reduceDB s
        putD s dbMaxLearnts (ml * 1.1)
      r <- search s (100 * luby 2 i)
      case r of
        Restart -> run (i + 1)
        Unsat -> return Unsatisfiable
        Sat -> Satisfiable <$> extractModel s

extractModel :: Solver s -> ST s Model
extractModel s = do
  let n = sNumVars s
  arr <- newArray (1, n) False :: ST s (STUArray s Int Bool)
  forM_ [1 .. n] $ \v -> do
    x <- litVal s (2 * v)
    unsafeWrite arr (v - 1) (x == valTrue)
  unsafeFreeze arr

-- | Decide a formula.  Total: the model of a satisfiable formula assigns every
-- variable @1..V@.
--
-- >>> solve (CNF 2 [[1, 2], [-1], [-2, 1]])
-- Unsatisfiable
solve :: CNF -> Result
solve (CNF n cs) = runST $ do
  s <- newSolver n
  ok <- addAll s cs
  if ok then solveSolver s else return Unsatisfiable
  where
    addAll _ [] = return True
    addAll s (c : r) = do
      ok <- addClause s c
      if ok then addAll s r else return False
