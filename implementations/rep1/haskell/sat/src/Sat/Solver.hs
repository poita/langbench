{-# LANGUAGE BangPatterns #-}
-- |
-- Module      : Sat.Solver
-- Description : MiniSat-style CDCL solver.
--
-- The solver follows the classic MiniSat design:
--
-- * __Propagation__ uses two watched literals per clause (with a cached
--   "blocker" literal per watch).
-- * __Learning__ is first-UIP conflict analysis followed by one level of
--   local (non-recursive) clause minimisation; unit learnt clauses are
--   asserted at level 0.
-- * __Branching__ is VSIDS: every variable met during analysis is bumped, the
--   increment grows by @1/0.95@ per conflict, and the unassigned variable of
--   highest activity is chosen from a heap. Decisions use phase saving
--   (initially false).
-- * __Restarts__ follow the Luby sequence: restart @i@ allows
--   @100 * luby 2 i@ conflicts.
-- * __Clause deletion__: after a restart, once at least @max_learnts@ learnt
--   clauses exist, the less active half (binary clauses excepted) is deleted
--   and @max_learnts@ is multiplied by 1.1.
--
-- Two interfaces are offered: the pure 'solveCNF' / 'solveCNFWith', and the
-- incremental-construction 'ST' interface ('newSolver', 'addClause',
-- 'solve', 'solverModel').
module Sat.Solver
  ( -- * Pure interface
    solveCNF
  , solveCNFWith
    -- * Configuration
  , Config (..)
  , defaultConfig
    -- * Mutable interface
  , Solver
  , newSolver
  , newSolverWith
  , addClause
  , solve
  , solverModel
  , Stats (..)
  , solverStats
  ) where

import Control.Monad (forM_, when)
import Control.Monad.ST (ST, runST)
import Data.Array.Base (unsafeRead, unsafeWrite)
import Data.Array.ST (STArray, STUArray, freeze, newArray, newArray_, newListArray)
import Data.Bits (shiftR, xor, (.&.))
import Data.Int (Int8)
import Data.List (sort, sortBy)
import Data.Ord (comparing)

import Sat.Internal.Heap
import Sat.Internal.Vec
import Sat.Luby (luby)
import Sat.Types

------------------------------------------------------------------------------
-- Configuration

-- | Tunable parameters. The defaults ('defaultConfig') are those required by
-- the specification; other values are mainly useful for stress-testing the
-- restart and clause-deletion machinery on small formulas.
data Config = Config
  { cfgRestartBase  :: !Int
    -- ^ Conflicts allowed in a Luby unit (default 100).
  , cfgMinLearnts   :: !Int
    -- ^ Lower bound of the initial @max_learnts@ (default 2000).
  , cfgLearntFactor :: !Double
    -- ^ Growth factor of @max_learnts@ after each reduction (default 1.1).
  } deriving (Eq, Show)

-- | @Config { cfgRestartBase = 100, cfgMinLearnts = 2000, cfgLearntFactor = 1.1 }@
defaultConfig :: Config
defaultConfig = Config 100 2000 1.1

-- | Counters describing a solver run.
data Stats = Stats
  { statConflicts    :: !Int
  , statDecisions    :: !Int
  , statPropagations :: !Int
  , statRestarts     :: !Int
  , statReductions   :: !Int
  , statLearnts      :: !Int   -- ^ learnt clauses currently stored
  } deriving (Eq, Show)

------------------------------------------------------------------------------
-- State
--
-- Literals are internal integers: variable @v@ (zero based) has the positive
-- literal @2v@ and the negative literal @2v+1@; @l `xor` 1@ negates.
-- Clauses are identified by a clause id (cid) indexing the clause tables; a
-- clause's literals live contiguously in one arena, the first two being the
-- watched ones.

-- | A solver instance living in the 'ST' state thread @s@.
data Solver s = Solver
  { sCfg      :: !Config
  , sNumVars  :: !Int
  , sVal      :: !(STUArray s Int Int8)      -- per literal: 1 true, -1 false, 0 unassigned
  , sLevel    :: !(STUArray s Int Int)       -- per variable
  , sReason   :: !(STUArray s Int Int)       -- per variable: cid or -1
  , sTrail    :: !(STUArray s Int Int)
  , sTrailLim :: !(STUArray s Int Int)
  , sSeen     :: !(STUArray s Int Int8)
  , sPhase    :: !(STUArray s Int Int8)      -- saved phase: 1 = true
  , sAct      :: !(STUArray s Int Double)    -- VSIDS activities
  , sHeap     :: !(Heap s)
  , sWatches  :: !(STArray s Int (Vec s Int)) -- per literal: (cid, blocker) pairs
  , sArena    :: !(Vec s Int)                -- clause literals
  , sCStart   :: !(Vec s Int)                -- per cid: offset into the arena
  , sCSize    :: !(Vec s Int)                -- per cid: number of literals
  , sCFlag    :: !(Vec s Int)                -- per cid: 0 input, 1 learnt, 2 free
  , sCAct     :: !(Vec s Double)             -- per cid: activity
  , sFreeCids :: !(Vec s Int)
  , sLearnts  :: !(Vec s Int)                -- cids of live learnt clauses
  , sOut      :: !(Vec s Int)                -- analysis: learnt clause under construction
  , sToClear  :: !(Vec s Int)                -- analysis: literals whose seen flag is set
  , sInts     :: !(STUArray s Int Int)       -- integer registers
  , sDbls     :: !(STUArray s Int Double)    -- double registers
  }

-- integer registers
rQhead, rTrailSize, rLevel, rOk, rNumInput, rWasted, rConflicts, rDecisions,
  rPropagations, rRestarts, rReductions :: Int
rQhead = 0
rTrailSize = 1
rLevel = 2
rOk = 3
rNumInput = 4
rWasted = 5
rConflicts = 6
rDecisions = 7
rPropagations = 8
rRestarts = 9
rReductions = 10

-- double registers
dVarInc, dClaInc, dMaxLearnts :: Int
dVarInc = 0
dClaInc = 1
dMaxLearnts = 2

rd :: Solver s -> Int -> ST s Int
rd s = unsafeRead (sInts s)
{-# INLINE rd #-}

wr :: Solver s -> Int -> Int -> ST s ()
wr s = unsafeWrite (sInts s)
{-# INLINE wr #-}

-- | Create a solver for variables @1..n@ with the default configuration.
newSolver :: Int -> ST s (Solver s)
newSolver = newSolverWith defaultConfig

-- | Create a solver for variables @1..n@.
newSolverWith :: Config -> Int -> ST s (Solver s)
newSolverWith cfg n = do
  val <- newArray (0, max 1 (2 * n) - 1) 0
  lvl <- newArray (0, max 1 n - 1) 0
  rsn <- newArray (0, max 1 n - 1) (-1)
  trl <- newArray (0, max 1 n - 1) 0
  lim <- newArray (0, n + 1) 0
  seen <- newArray (0, max 1 n - 1) 0
  ph <- newArray (0, max 1 n - 1) 0
  act <- newArray (0, max 1 n - 1) 0
  heap <- newHeap n act
  forM_ [0 .. n - 1] (heapInsert heap)
  ws <- do
    vs <- mapM (const (newVec 4)) [1 .. max 1 (2 * n)]
    newListArray (0, max 1 (2 * n) - 1) vs
  arena <- newVec 1024
  cs <- newVec 256
  cz <- newVec 256
  cf <- newVec 256
  ca <- newVec 256
  fr <- newVec 16
  ls <- newVec 256
  out <- newVec 64
  tc <- newVec 64
  ints <- newArray (0, 15) 0
  dbls <- newArray (0, 3) 0
  unsafeWrite ints rOk 1
  unsafeWrite dbls dVarInc 1
  unsafeWrite dbls dClaInc 1
  return Solver
    { sCfg = cfg, sNumVars = n, sVal = val, sLevel = lvl, sReason = rsn
    , sTrail = trl, sTrailLim = lim, sSeen = seen, sPhase = ph, sAct = act
    , sHeap = heap, sWatches = ws, sArena = arena, sCStart = cs, sCSize = cz
    , sCFlag = cf, sCAct = ca, sFreeCids = fr, sLearnts = ls, sOut = out
    , sToClear = tc, sInts = ints, sDbls = dbls }

------------------------------------------------------------------------------
-- Literals and assignment

-- DIMACS literal -> internal literal
toLit :: Int -> Int
toLit l
  | l > 0     = 2 * (l - 1)
  | otherwise = 2 * (negate l - 1) + 1
{-# INLINE toLit #-}

litVar :: Int -> Int
litVar l = l `shiftR` 1
{-# INLINE litVar #-}

litVal :: Solver s -> Int -> ST s Int8
litVal s = unsafeRead (sVal s)
{-# INLINE litVal #-}

-- | Assign a literal true at the current decision level.
enqueue :: Solver s -> Int -> Int -> ST s ()
enqueue s l reason = do
  let v = litVar l
  lvl <- rd s rLevel
  unsafeWrite (sVal s) l 1
  unsafeWrite (sVal s) (l `xor` 1) (-1)
  unsafeWrite (sLevel s) v lvl
  unsafeWrite (sReason s) v reason
  ts <- rd s rTrailSize
  unsafeWrite (sTrail s) ts l
  wr s rTrailSize (ts + 1)

newDecisionLevel :: Solver s -> ST s ()
newDecisionLevel s = do
  lvl <- rd s rLevel
  ts <- rd s rTrailSize
  unsafeWrite (sTrailLim s) lvl ts
  wr s rLevel (lvl + 1)

-- | Undo all assignments above the given decision level, saving phases.
cancelUntil :: Solver s -> Int -> ST s ()
cancelUntil s lvl = do
  cur <- rd s rLevel
  when (cur > lvl) $ do
    lim <- unsafeRead (sTrailLim s) lvl
    ts <- rd s rTrailSize
    let go i = when (i >= lim) $ do
          x <- unsafeRead (sTrail s) i
          let v = litVar x
          unsafeWrite (sVal s) x 0
          unsafeWrite (sVal s) (x `xor` 1) 0
          unsafeWrite (sPhase s) v (if x .&. 1 == 0 then 1 else 0)
          unsafeWrite (sReason s) v (-1)
          heapInsert (sHeap s) v
          go (i - 1)
    go (ts - 1)
    wr s rTrailSize lim
    wr s rQhead lim
    wr s rLevel lvl

------------------------------------------------------------------------------
-- Clause database

-- | Store a clause (at least two literals) and watch its first two literals.
allocClause :: Solver s -> [Int] -> Bool -> ST s Int
allocClause s lits learnt = do
  start <- vecSize (sArena s)
  mapM_ (vecPush (sArena s)) lits
  let sz = length lits
      flag = if learnt then 1 else 0
  nfree <- vecSize (sFreeCids s)
  cid <-
    if nfree > 0
      then do
        c <- vecPop (sFreeCids s)
        vecWrite (sCStart s) c start
        vecWrite (sCSize s) c sz
        vecWrite (sCFlag s) c flag
        vecWrite (sCAct s) c 0
        return c
      else do
        c <- vecSize (sCStart s)
        vecPush (sCStart s) start
        vecPush (sCSize s) sz
        vecPush (sCFlag s) flag
        vecPush (sCAct s) 0
        return c
  case lits of
    (a : b : _) -> do
      watch s a cid b
      watch s b cid a
    _ -> error "allocClause: clause too short"
  return cid

watch :: Solver s -> Int -> Int -> Int -> ST s ()
watch s lit cid blocker = do
  w <- unsafeRead (sWatches s) lit
  vecPush w cid
  vecPush w blocker
{-# INLINE watch #-}

-- | Add an input clause given as DIMACS literals. The clause is simplified at
-- the root: duplicate literals, tautologies and satisfied clauses are dropped,
-- falsified literals removed, and units are assigned and propagated.
--
-- Must be called before 'solve'.
addClause :: Solver s -> [Int] -> ST s ()
addClause s ints = do
  ok <- rd s rOk
  when (ok /= 0) $ do
    let ls = dedup (sort (map toLit ints))
    if tautology ls
      then return ()
      else do
        vals <- mapM (litVal s) ls
        if any (> 0) vals
          then return ()
          else case [ l | (l, v) <- zip ls vals, v == 0 ] of
            [] -> wr s rOk 0
            [u] -> do
              enqueue s u (-1)
              c <- propagate s
              when (c >= 0) (wr s rOk 0)
            rest -> do
              _ <- allocClause s rest False
              n <- rd s rNumInput
              wr s rNumInput (n + 1)
  where
    dedup (a : b : r) | a == b = dedup (b : r)
                      | otherwise = a : dedup (b : r)
    dedup r = r
    tautology (a : b : r) = (a `xor` 1 == b) || tautology (b : r)
    tautology _ = False

------------------------------------------------------------------------------
-- Propagation

-- | Unit propagation over the two-watched-literal scheme. Returns the cid of
-- a conflicting clause, or @-1@.
propagate :: Solver s -> ST s Int
propagate s = do
  arena <- vecData (sArena s)
  cstart <- vecData (sCStart s)
  csize <- vecData (sCSize s)
  let val = sVal s
      outer = do
        qh <- rd s rQhead
        ts <- rd s rTrailSize
        if qh >= ts
          then return (-1)
          else do
            p <- unsafeRead (sTrail s) qh
            wr s rQhead (qh + 1)
            np <- rd s rPropagations
            wr s rPropagations (np + 1)
            let falseLit = p `xor` 1
            ws <- unsafeRead (sWatches s) falseLit
            n <- vecSize ws
            wd <- vecData ws
            r <- inner falseLit ws wd n 0 0
            if r >= 0 then return r else outer
      inner !falseLit ws wd !n !i !j
        | i >= n = vecSetSize ws j >> return (-1)
        | otherwise = do
            cid <- unsafeRead wd i
            blk <- unsafeRead wd (i + 1)
            bv <- unsafeRead val blk
            if bv > 0
              then keep wd j cid blk >> inner falseLit ws wd n (i + 2) (j + 2)
              else do
                st <- unsafeRead cstart cid
                sz <- unsafeRead csize cid
                l0 <- unsafeRead arena st
                first <-
                  if l0 == falseLit
                    then do
                      l1 <- unsafeRead arena (st + 1)
                      unsafeWrite arena st l1
                      unsafeWrite arena (st + 1) l0
                      return l1
                    else return l0
                fv <- unsafeRead val first
                if fv > 0
                  then keep wd j cid first >> inner falseLit ws wd n (i + 2) (j + 2)
                  else do
                    let findWatch k
                          | k >= st + sz = return (-1)
                          | otherwise = do
                              lk <- unsafeRead arena k
                              v <- unsafeRead val lk
                              if v >= 0 then return k else findWatch (k + 1)
                    k <- findWatch (st + 2)
                    if k >= 0
                      then do
                        lk <- unsafeRead arena k
                        unsafeWrite arena (st + 1) lk
                        unsafeWrite arena k falseLit
                        watch s lk cid first
                        inner falseLit ws wd n (i + 2) j
                      else do
                        keep wd j cid first
                        if fv < 0
                          then do
                            -- conflict: keep the remaining watches
                            let copy a b
                                  | a >= n = return b
                                  | otherwise = do
                                      unsafeRead wd a >>= unsafeWrite wd b
                                      copy (a + 1) (b + 1)
                            j' <- copy (i + 2) (j + 2)
                            vecSetSize ws j'
                            ts <- rd s rTrailSize
                            wr s rQhead ts
                            return cid
                          else do
                            enqueue s first cid
                            inner falseLit ws wd n (i + 2) (j + 2)
      keep wd j cid blk = unsafeWrite wd j cid >> unsafeWrite wd (j + 1) blk
  outer

------------------------------------------------------------------------------
-- Activities

varBump :: Solver s -> Int -> ST s ()
varBump s v = do
  a <- unsafeRead (sAct s) v
  inc <- unsafeRead (sDbls s) dVarInc
  let a' = a + inc
  unsafeWrite (sAct s) v a'
  when (a' > 1e100) $ do
    forM_ [0 .. sNumVars s - 1] $ \i -> do
      x <- unsafeRead (sAct s) i
      unsafeWrite (sAct s) i (x * 1e-100)
    unsafeWrite (sDbls s) dVarInc (inc * 1e-100)
  heapIncreased (sHeap s) v

claBump :: Solver s -> Int -> ST s ()
claBump s c = do
  a <- vecRead (sCAct s) c
  inc <- unsafeRead (sDbls s) dClaInc
  let a' = a + inc
  vecWrite (sCAct s) c a'
  when (a' > 1e20) $ do
    ls <- vecToList (sLearnts s)
    forM_ ls $ \i -> do
      x <- vecRead (sCAct s) i
      vecWrite (sCAct s) i (x * 1e-20)
    unsafeWrite (sDbls s) dClaInc (inc * 1e-20)

decayActivities :: Solver s -> ST s ()
decayActivities s = do
  vi <- unsafeRead (sDbls s) dVarInc
  unsafeWrite (sDbls s) dVarInc (vi / 0.95)
  ci <- unsafeRead (sDbls s) dClaInc
  unsafeWrite (sDbls s) dClaInc (ci / 0.999)

------------------------------------------------------------------------------
-- Conflict analysis

-- | First-UIP analysis of a conflicting clause. Leaves the minimised learnt
-- clause in 'sOut' (asserting literal first, a literal of the backjump level
-- second) and returns the backjump level.
analyze :: Solver s -> Int -> ST s Int
analyze s confl0 = do
  let out = sOut s
  vecClear out
  vecPush out 0
  curLvl <- rd s rLevel
  ts <- rd s rTrailSize
  arena <- vecData (sArena s)
  let loop !confl !p !idx !pathC = do
        fl <- vecRead (sCFlag s) confl
        when (fl == 1) (claBump s confl)
        st <- vecRead (sCStart s) confl
        sz <- vecRead (sCSize s) confl
        let first = if p < 0 then st else st + 1
            lits !j !pc
              | j >= st + sz = return pc
              | otherwise = do
                  q <- unsafeRead arena j
                  let v = litVar q
                  sn <- unsafeRead (sSeen s) v
                  lv <- unsafeRead (sLevel s) v
                  if sn == 0 && lv > 0
                    then do
                      varBump s v
                      unsafeWrite (sSeen s) v 1
                      if lv >= curLvl
                        then lits (j + 1) (pc + 1)
                        else vecPush out q >> lits (j + 1) pc
                    else lits (j + 1) pc
        pc' <- lits first pathC
        let scan i = do
              x <- unsafeRead (sTrail s) i
              sn <- unsafeRead (sSeen s) (litVar x)
              if sn /= 0 then return i else scan (i - 1)
        i <- scan idx
        pl <- unsafeRead (sTrail s) i
        r <- unsafeRead (sReason s) (litVar pl)
        unsafeWrite (sSeen s) (litVar pl) 0
        if pc' - 1 > 0
          then loop r pl (i - 1) (pc' - 1)
          else return pl
  pl <- loop confl0 (-1) (ts - 1) (0 :: Int)
  vecWrite out 0 (pl `xor` 1)
  -- remember every literal whose seen flag is set, for clearing later
  n0 <- vecSize out
  vecClear (sToClear s)
  forM_ [1 .. n0 - 1] $ \i -> vecRead out i >>= vecPush (sToClear s)
  -- local minimisation: drop literals implied by the other seen literals
  let minim !i !j
        | i >= n0 = return j
        | otherwise = do
            l <- vecRead out i
            r <- unsafeRead (sReason s) (litVar l)
            keepIt <-
              if r < 0
                then return True
                else do
                  st <- vecRead (sCStart s) r
                  sz <- vecRead (sCSize s) r
                  let chk k
                        | k >= st + sz = return False
                        | otherwise = do
                            q <- unsafeRead arena k
                            let v = litVar q
                            sn <- unsafeRead (sSeen s) v
                            lv <- unsafeRead (sLevel s) v
                            if sn == 0 && lv > 0 then return True else chk (k + 1)
                  chk (st + 1)
            if keepIt
              then vecWrite out j l >> minim (i + 1) (j + 1)
              else minim (i + 1) j
  n1 <- minim 1 1
  vecTruncate out n1
  tc <- vecToList (sToClear s)
  forM_ tc $ \l -> unsafeWrite (sSeen s) (litVar l) 0
  -- backjump level: highest level among the non-asserting literals
  if n1 == 1
    then return 0
    else do
      let best !i !bi !bl
            | i >= n1 = return (bi, bl)
            | otherwise = do
                l <- vecRead out i
                lv <- unsafeRead (sLevel s) (litVar l)
                if lv > bl then best (i + 1) i lv else best (i + 1) bi bl
      l1 <- vecRead out 1
      lv1 <- unsafeRead (sLevel s) (litVar l1)
      (bi, bl) <- best 2 1 lv1
      when (bi /= 1) $ do
        a <- vecRead out 1
        b <- vecRead out bi
        vecWrite out 1 b
        vecWrite out bi a
      return bl

------------------------------------------------------------------------------
-- Clause deletion

-- | Delete the less active half of the learnt clauses (keeping binary ones
-- and clauses that are the reason of an assignment).
reduceDB :: Solver s -> ST s ()
reduceDB s = do
  cids <- vecToList (sLearnts s)
  items <- mapM (\c -> do a <- vecRead (sCAct s) c
                          z <- vecRead (sCSize s) c
                          return (c, a, z)) cids
  let sorted = sortBy (comparing key) items
      key (_, a, z) = (z <= 2, a)
      half = length items `div` 2
      (cands, rest) = splitAt half sorted
  keptCands <- fmap concat . mapM (\it@(c, _, z) -> do
      lk <- locked c
      if z > 2 && not lk
        then deleteClause c >> return []
        else return [it]) $ cands
  let survivors = [ c | (c, _, _) <- keptCands ++ rest ]
  vecFromList (sLearnts s) survivors
  -- drop the watches of deleted clauses
  forM_ [0 .. 2 * sNumVars s - 1] $ \l -> do
    ws <- unsafeRead (sWatches s) l
    n <- vecSize ws
    wd <- vecData ws
    let go !i !j
          | i >= n = vecSetSize ws j
          | otherwise = do
              c <- unsafeRead wd i
              b <- unsafeRead wd (i + 1)
              f <- vecRead (sCFlag s) c
              if f == 2
                then go (i + 2) j
                else unsafeWrite wd j c >> unsafeWrite wd (j + 1) b >> go (i + 2) (j + 2)
    go 0 0
  compactArena s
  where
    locked c = do
      st <- vecRead (sCStart s) c
      l0 <- vecRead (sArena s) st
      v <- litVal s l0
      r <- unsafeRead (sReason s) (litVar l0)
      return (v > 0 && r == c)
    deleteClause c = do
      z <- vecRead (sCSize s) c
      vecWrite (sCFlag s) c 2
      w <- rd s rWasted
      wr s rWasted (w + z)
      vecPush (sFreeCids s) c

-- | Squeeze deleted clauses out of the literal arena when over half of it is
-- garbage.
compactArena :: Solver s -> ST s ()
compactArena s = do
  wasted <- rd s rWasted
  total <- vecSize (sArena s)
  when (wasted * 2 > total) $ do
    old <- vecData (sArena s)
    ncid <- vecSize (sCStart s)
    new <- newVec (total - wasted + 16)
    forM_ [0 .. ncid - 1] $ \c -> do
      f <- vecRead (sCFlag s) c
      when (f /= 2) $ do
        st <- vecRead (sCStart s) c
        sz <- vecRead (sCSize s) c
        ns <- vecSize new
        vecWrite (sCStart s) c ns
        forM_ [st .. st + sz - 1] $ \k -> unsafeRead old k >>= vecPush new
    newArr <- vecData new
    n' <- vecSize new
    -- move the compacted contents back into the solver's arena vector
    vecClear (sArena s)
    forM_ [0 .. n' - 1] $ \k -> unsafeRead newArr k >>= vecPush (sArena s)
    wr s rWasted 0

------------------------------------------------------------------------------
-- Search

data SearchResult = SearchSat | SearchUnsat | SearchRestart

-- | Pick the unassigned variable of highest activity, as a literal with its
-- saved phase; @-1@ if every variable is assigned.
pickBranch :: Solver s -> ST s Int
pickBranch s = go
  where
    go = do
      v <- heapRemoveMax (sHeap s)
      if v < 0
        then return (-1)
        else do
          x <- litVal s (2 * v)
          if x /= 0
            then go
            else do
              ph <- unsafeRead (sPhase s) v
              return (if ph /= 0 then 2 * v else 2 * v + 1)

search :: Solver s -> Int -> ST s SearchResult
search s nof = loop 0
  where
    loop !confls = do
      confl <- propagate s
      if confl >= 0
        then do
          nc <- rd s rConflicts
          wr s rConflicts (nc + 1)
          lvl <- rd s rLevel
          if lvl == 0
            then return SearchUnsat
            else do
              bt <- analyze s confl
              cancelUntil s bt
              lits <- vecToList (sOut s)
              case lits of
                [u] -> enqueue s u (-1)
                (a : _) -> do
                  cid <- allocClause s lits True
                  vecPush (sLearnts s) cid
                  claBump s cid
                  enqueue s a cid
                [] -> error "search: empty learnt clause"
              decayActivities s
              loop (confls + 1 :: Int)
        else
          if confls >= nof
            then cancelUntil s 0 >> return SearchRestart
            else do
              l <- pickBranch s
              if l < 0
                then return SearchSat
                else do
                  nd <- rd s rDecisions
                  wr s rDecisions (nd + 1)
                  newDecisionLevel s
                  enqueue s l (-1)
                  loop confls

-- | Decide satisfiability of the clauses added so far. On 'True' a model is
-- available through 'solverModel'.
solve :: Solver s -> ST s Bool
solve s = do
  ok <- rd s rOk
  if ok == 0
    then return False
    else do
      c <- propagate s
      if c >= 0
        then wr s rOk 0 >> return False
        else do
          ni <- rd s rNumInput
          unsafeWrite (sDbls s) dMaxLearnts
            (fromIntegral (max (ni `div` 3) (cfgMinLearnts (sCfg s))))
          run 0
  where
    run !i = do
      r <- search s (cfgRestartBase (sCfg s) * luby 2 i)
      case r of
        SearchSat -> return True
        SearchUnsat -> wr s rOk 0 >> return False
        SearchRestart -> do
          nr <- rd s rRestarts
          wr s rRestarts (nr + 1)
          n <- vecSize (sLearnts s)
          ml <- unsafeRead (sDbls s) dMaxLearnts
          when (fromIntegral n >= ml) $ do
            reduceDB s
            nd <- rd s rReductions
            wr s rReductions (nd + 1)
            unsafeWrite (sDbls s) dMaxLearnts (ml * cfgLearntFactor (sCfg s))
          run (i + 1)

-- | The model found by the last successful 'solve'. Only meaningful when
-- 'solve' returned 'True' (the solver is left at the satisfying assignment).
solverModel :: Solver s -> ST s Model
solverModel s = do
  let n = sNumVars s
  arr <- newArray_ (1, n) :: ST s (STUArray s Int Bool)
  forM_ [1 .. n] $ \v -> do
    x <- litVal s (2 * (v - 1))
    unsafeWrite arr (v - 1) (x > 0)
  freeze arr

-- | Counters of the work done so far.
solverStats :: Solver s -> ST s Stats
solverStats s = do
  c <- rd s rConflicts
  d <- rd s rDecisions
  p <- rd s rPropagations
  r <- rd s rRestarts
  x <- rd s rReductions
  l <- vecSize (sLearnts s)
  return (Stats c d p r x l)

------------------------------------------------------------------------------
-- Pure interface

-- | Solve a formula with the default configuration.
solveCNF :: CNF -> Result
solveCNF = solveCNFWith defaultConfig

-- | Solve a formula with an explicit configuration.
solveCNFWith :: Config -> CNF -> Result
solveCNFWith cfg (CNF n cs) = runST $ do
  s <- newSolverWith cfg n
  mapM_ (addClause s) cs
  sat <- solve s
  if sat then Sat <$> solverModel s else return Unsat
