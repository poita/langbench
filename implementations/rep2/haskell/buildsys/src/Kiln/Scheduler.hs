-- | The deterministic event-driven scheduler simulation.
module Kiln.Scheduler
  ( EventKind (..)
  , Event (..)
  , SchedResult (..)
  , schedule
  ) where

import Data.Array
import qualified Data.ByteString as B
import qualified Data.IntMap.Strict as IM
import Data.List (sortOn)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

import Kiln.Command
import Kiln.Error
import Kiln.Graph
import Kiln.Hash
import Kiln.State
import Kiln.Step
import Kiln.Workspace

-- | What happened to a step.
data EventKind = Hit | Ran | Failed | Cancelled
  deriving (Eq, Show)

-- | A log event. For a 'Hit', start and end are both the time of the hit and
-- the worker is 0 (unused).
data Event = Event
  { evKind :: !EventKind
  , evSerial :: !Int
  , evStart :: !Int
  , evEnd :: !Int
  , evWorker :: !Int
  , evTarget :: !B.ByteString
  , evCommand :: !B.ByteString
  }
  deriving (Eq, Show)

-- | The outcome of simulating one build.
data SchedResult = SchedResult
  { srEvents :: [Event]
    -- ^ sorted by start time, then serial
  , srError :: Maybe BuildError
  , srRan :: !Int
  , srHits :: !Int
  , srTime :: !Int
    -- ^ the completion time
  , srWorkspace :: Workspace
  , srState :: StateMap
  }

data Running = Running
  { rStep :: Step
  , rEnd :: !Int
  , rResult :: Either BuildError CmdOutput
  , rIns :: [(Path, Hash)]
  , rDeps :: [(Path, Hash)]
  }

data S = S
  { sTime :: !Int
  , sWs :: !Workspace
  , sState :: !StateMap
  , sPending :: !(IM.IntMap Int)
  , sUndecided :: !(S.Set Int)
  , sStale :: !(S.Set Int)
  , sRunning :: !(M.Map Int Running)
  , sEvents :: !(IM.IntMap Event)
  , sRan :: !Int
  , sHits :: !Int
  }

-- | Simulate a build of the reachable nodes on @workers@ workers against the
-- workspace and the previously recorded state.
schedule :: Index -> S.Set Node -> Int -> Workspace -> StateMap -> SchedResult
schedule ix reach workers ws0 state0 = loop s0
  where
    nodes = S.toList reach
    nodeId = M.fromList (zip nodes [0 :: Int ..])
    nodeArr = listArray (0, length nodes - 1) nodes :: Array Int Node
    succIds = [[nodeId M.! m | m <- successors ix n] | n <- nodes]
    dependents :: Array Int [Int]
    dependents =
      accumArray (flip (:)) [] (0, length nodes - 1)
        [(m, i) | (i, ms) <- zip [0 ..] succIds, m <- reverse ms]
    serialId = IM.fromList [(sr, i) | (i, NStep sr) <- zip [0 ..] nodes]
    stepOf serial = ixSteps ix ! serial

    s0 =
      complete0
        S
          { sTime = 0
          , sWs = ws0
          , sState = state0
          , sPending = IM.fromList (zip [0 ..] (map length succIds))
          , sUndecided = S.fromList [sr | (NStep sr, []) <- zip nodes succIds]
          , sStale = S.empty
          , sRunning = M.empty
          , sEvents = IM.empty
          , sRan = 0
          , sHits = 0
          }
    -- sources, and phony nodes with no dependencies, complete at time 0
    complete0 s =
      foldl'
        (\acc (i, n, deps) -> case n of
            NSource _ -> complete i acc
            NPhony _ | null deps -> complete i acc
            _ -> acc)
        s
        (zip3 [0 ..] nodes succIds)

    complete :: Int -> S -> S
    complete i s = foldl' dec s (dependents ! i)
      where
        dec acc d =
          let p = sPending acc IM.! d - 1
              acc' = acc {sPending = IM.insert d p (sPending acc)}
           in if p /= 0
                then acc'
                else case nodeArr ! d of
                  NStep sr -> acc' {sUndecided = S.insert sr (sUndecided acc')}
                  NPhony _ -> complete d acc'
                  NSource _ -> acc'

    -- (A) settle cache hits
    settle s = case S.minView (sUndecided s) of
      Nothing -> s
      Just (serial, rest) ->
        let st = stepOf serial
            cmd = renderCommand (stepCommand st)
            fresh =
              isFresh (sWs s) (M.lookup (stepPrimary st) (sState s)) cmd (stepOutputs st) (stepFileInputs st)
         in if fresh
              then
                settle . complete (serialId IM.! serial) $
                  s
                    { sUndecided = rest
                    , sHits = sHits s + 1
                    , sEvents = IM.insert serial (Event Hit serial (sTime s) (sTime s) 0 (stepPrimary st) cmd) (sEvents s)
                    }
              else settle s {sUndecided = rest, sStale = S.insert serial (sStale s)}

    -- (B) dispatch
    dispatch s = case S.minView (sStale s) of
      Just (serial, rest)
        | w : _ <- [w | w <- [0 .. workers - 1], not (M.member w (sRunning s))] ->
            let st = stepOf serial
                snapshot = sWs s
                inputs = [(p, f) | p <- stepFileInputs st, Just f <- [lookupFile p snapshot]]
                result = runCommand (stepCommand st) inputs snapshot
                deps = case result of
                  Right o -> [(p, fileHash f) | p <- coDiscovered o, Just f <- [lookupFile p snapshot]]
                  Left _ -> []
                end = sTime s + stepCost st
                run =
                  Running
                    { rStep = st
                    , rEnd = end
                    , rResult = result
                    , rIns = [(p, fileHash f) | (p, f) <- inputs]
                    , rDeps = deps
                    }
                ev = Event Ran serial (sTime s) end w (stepPrimary st) (renderCommand (stepCommand st))
             in dispatch
                  s
                    { sStale = rest
                    , sRunning = M.insert w run (sRunning s)
                    , sEvents = IM.insert serial ev (sEvents s)
                    }
      _ -> s

    -- (C) advance the clock
    loop s0' =
      let s1 = dispatch (settle s0')
       in if M.null (sRunning s1)
            then finish s1 Nothing
            else
              let t = minimum (map rEnd (M.elems (sRunning s1)))
                  done = [(w, r) | (w, r) <- M.toAscList (sRunning s1), rEnd r == t]
                  s2 = s1 {sTime = t, sRunning = foldl' (flip M.delete) (sRunning s1) (map fst done)}
                  (s3, failed) = foldl' finishOne (s2, []) done
               in case failed of
                    [] -> loop (foldl' (\acc (_, r) -> complete (serialId IM.! stepSerial (rStep r)) acc) s3 done)
                    _ ->
                      let (_, err) = minimum' failed
                          cancelled = M.elems (sRunning s3)
                          cancelSerials = map (stepSerial . rStep) cancelled
                          failSerials = map fst failed
                          ev' = foldl' (\m sr -> IM.adjust (\e -> e {evKind = Cancelled}) sr m) (sEvents s3) cancelSerials
                          ev'' = foldl' (\m sr -> IM.adjust (\e -> e {evKind = Failed}) sr m) ev' failSerials
                          dropEntries = [stepPrimary (stepOf sr) | sr <- cancelSerials ++ failSerials]
                          st' = foldl' (flip M.delete) (sState s3) dropEntries
                       in finish s3 {sEvents = ev'', sState = st', sRunning = M.empty} (Just err)
    minimum' = foldr1 (\a b -> if fst a <= fst b then a else b)

    finishOne (s, failed) (_, r) = case rResult r of
      Left e -> (s, failed ++ [(stepSerial (rStep r), e)])
      Right out ->
        let st = rStep r
            contents = coContent out : maybe [] pure (coDepfile out)
            files = [(p, mkFile c) | (p, c) <- zip (stepOutputs st) contents]
            ws' = foldl' (\w (p, f) -> insertFile p f w) (sWs s) files
            entry =
              Entry
                { entCmd = renderCommand (stepCommand st)
                , entIns = rIns r
                , entDeps = rDeps r
                , entOuts = [(p, fileHash f) | (p, f) <- files]
                }
         in ( s
                { sWs = ws'
                , sState = M.insert (stepPrimary st) entry (sState s)
                , sRan = sRan s + 1
                }
            , failed
            )

    finish s err =
      let evs = sortOn (\e -> (evStart e, evSerial e)) (IM.elems (sEvents s))
       in SchedResult
            { srEvents = evs
            , srError = err
            , srRan = sRan s
            , srHits = sHits s
            , srTime = maximum (0 : map evEnd evs)
            , srWorkspace = sWs s
            , srState = sState s
            }
