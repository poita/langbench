-- | The deterministic scheduling simulation: ready sets ordered by serial,
-- lowest-id-first worker allocation, freshness decided when a step becomes
-- ready, and cancellation on execution errors.
module Kiln.Scheduler
  ( Event (..)
  , EventKind (..)
  , Stats (..)
  , SchedResult (..)
  , schedule
  ) where

import Data.Array ((!))
import qualified Data.ByteString as BS
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.List (minimumBy, sortOn)
import qualified Data.Map.Strict as Map
import Data.Ord (comparing)

import Kiln.Command (CmdResult (..), renderCommand, runCommand)
import Kiln.Error
import Kiln.Graph
import Kiln.Hash (Hash)
import Kiln.State
import Kiln.Step
import Kiln.Workspace (Workspace, fileHash, lookupFile)
import qualified Kiln.Workspace as Workspace

data EventKind = Hit | Run | Fail | Cancel
  deriving (Eq, Show)

-- | One log event of a build.
data Event = Event
  { evKind :: !EventKind
  , evStart :: !Int
    -- ^ for a hit, its time
  , evEnd :: !Int
  , evWorker :: !Int
  , evSerial :: !Int
  , evTarget :: !BS.ByteString
  , evCommand :: !BS.ByteString
  }
  deriving (Eq, Show)

-- | Summary of a successful build.
data Stats = Stats
  { statRan :: !Int
  , statHit :: !Int
  , statTime :: !Int
  }
  deriving (Eq, Show)

data SchedResult = SchedResult
  { srWorkspace :: Workspace
  , srState :: StateMap
  , srEvents :: [Event]
    -- ^ sorted by start time, then step serial
  , srOutcome :: Either KilnError Stats
  }

-- | A dispatched command: it has read its inputs (the result is computed
-- from the dispatch-time snapshot) and will write at its end time.
data Running = Running
  { rWorker :: !Int
  , rSerial :: !Int
  , rStart :: !Int
  , rEnd :: !Int
  , rResult :: Either KilnError CmdResult
  , rIns :: [(BS.ByteString, Hash)]
  }

data Sim = Sim
  { sTime :: !Int
  , sWs :: Workspace
  , sState :: StateMap
  , sPending :: !(IntMap Int)
  , sUndecided :: !IS.IntSet
  , sStale :: !IS.IntSet
  , sRunning :: !(IntMap Running)
    -- ^ keyed by worker id
  , sEvents :: [Event]
  , sRan :: !Int
  , sHits :: !Int
  , sMaxTime :: !Int
  }

-- | Simulate a build over the reachable set with @workers@ workers.
schedule :: Graph -> IS.IntSet -> Int -> Workspace -> StateMap -> SchedResult
schedule g reach workers ws0 state0 = loop start
  where
    -- dependents (reverse ordering edges) of every reachable node
    dependents :: IntMap [Int]
    dependents =
      IM.fromListWith
        (++)
        [(m, [n]) | n <- IS.toList reach, m <- grSucc g ! n]

    step n = grSteps g ! n

    start =
      let pending = IM.fromList [(n, length (grSucc g ! n)) | n <- IS.toList reach]
          sim0 =
            Sim
              { sTime = 0
              , sWs = ws0
              , sState = state0
              , sPending = pending
              , sUndecided = IS.empty
              , sStale = IS.empty
              , sRunning = IM.empty
              , sEvents = []
              , sRan = 0
              , sHits = 0
              , sMaxTime = 0
              }
          roots = [n | (n, 0) <- IM.toAscList pending]
       in foldl' (\s n -> if isStepNode g n then s {sUndecided = IS.insert n (sUndecided s)} else complete n s) sim0 roots

    -- completing a node releases its dependents; phonies complete instantly
    complete :: Int -> Sim -> Sim
    complete n sim = foldl' release sim (IM.findWithDefault [] n dependents)
      where
        release s d =
          let p = IM.findWithDefault 0 d (sPending s) - 1
              s' = s {sPending = IM.insert d p (sPending s)}
           in if p /= 0
                then s'
                else
                  if isStepNode g d
                    then s' {sUndecided = IS.insert d (sUndecided s')}
                    else complete d s'

    loop sim0 =
      let sim1 = dispatch (settle sim0)
       in if IM.null (sRunning sim1) then finish sim1 else advance sim1

    finish sim =
      SchedResult
        (sWs sim)
        (sState sim)
        (sortEvents (sEvents sim))
        (Right (Stats (sRan sim) (sHits sim) (sMaxTime sim)))

    -- (A) settle cache hits at the current time
    settle sim = case IS.minView (sUndecided sim) of
      Nothing -> sim
      Just (n, rest) ->
        let s = step n
            sim' = sim {sUndecided = rest}
         in if isFresh (sWs sim) s (Map.lookup (stepPrimary s) (sState sim))
              then
                settle . complete n $
                  sim'
                    { sHits = sHits sim' + 1
                    , sEvents = Event Hit (sTime sim) (sTime sim) 0 n (stepPrimary s) (renderCommand (stepCommand s)) : sEvents sim'
                    , sMaxTime = max (sMaxTime sim') (sTime sim)
                    }
              else settle sim' {sStale = IS.insert n (sStale sim')}

    -- (B) dispatch ready steps to free workers
    dispatch sim = case IS.minView (sStale sim) of
      Nothing -> sim
      Just (n, rest) -> case [w | w <- [0 .. workers - 1], not (IM.member w (sRunning sim))] of
        [] -> sim
        w : _ ->
          let s = step n
              ws = sWs sim
              ins = stepFileInputs s
              result = runCommand ws (stepCommand s) ins (stepFullOutputs s)
              hashes = [(p, maybe 0 fileHash (lookupFile p ws)) | p <- ins]
              end = sTime sim + stepCost s
           in dispatch
                sim
                  { sStale = rest
                  , sRunning = IM.insert w (Running w n (sTime sim) end result hashes) (sRunning sim)
                  , sMaxTime = max (sMaxTime sim) end
                  }

    -- (C) advance the clock to the next completion
    advance sim =
      let t = minimum (map rEnd (IM.elems (sRunning sim)))
          finishing = [r | r <- IM.elems (sRunning sim), rEnd r == t]
          sim1 = sim {sTime = t, sRunning = foldr (IM.delete . rWorker) (sRunning sim) finishing}
          (sim2, failed) = foldl' (finishOne) (sim1, []) finishing
       in case failed of
            [] -> loop (foldl' (\s r -> complete (rSerial r) s) sim2 finishing)
            _ ->
              let (_, firstErr) = minimumBy (comparing (rSerial . fst)) failed
                  cancelled = IM.elems (sRunning sim2)
                  events =
                    [event Cancel r | r <- cancelled]
                      ++ [event Fail r | (r, _) <- failed]
                  st' =
                    foldr
                      (Map.delete . stepPrimary . step . rSerial)
                      (sState sim2)
                      (cancelled ++ map fst failed)
               in SchedResult (sWs sim2) st' (sortEvents (events ++ sEvents sim2)) (Left firstErr)

    -- apply one finished command: write outputs and replace its state entry
    finishOne (sim, failed) r = case rResult r of
      Left e -> (sim, failed ++ [(r, e)])
      Right res ->
        let s = step (rSerial r)
            ws' = foldl' (\w (p, c) -> Workspace.insert p c w) (sWs sim) (resultFiles res)
            outs = [(p, maybe 0 fileHash (lookupFile p ws')) | (p, _) <- resultFiles res]
            entry = Entry (renderCommand (stepCommand s)) (rIns r) (resultDeps res) outs
            sim' =
              sim
                { sWs = ws'
                , sState = Map.insert (stepPrimary s) entry (sState sim)
                , sRan = sRan sim + 1
                , sEvents = event Run r : sEvents sim
                }
         in (sim', failed)

    event kind r =
      let s = step (rSerial r)
       in Event kind (rStart r) (rEnd r) (rWorker r) (rSerial r) (stepPrimary s) (renderCommand (stepCommand s))

sortEvents :: [Event] -> [Event]
sortEvents = sortOn (\e -> (evStart e, evSerial e))
