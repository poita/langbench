-- | One complete build: configuration, scheduling and state persistence.
module Kiln.Build
  ( BuildRequest (..)
  , BuildSummary (..)
  , BuildOutcome (..)
  , build
  ) where

import qualified Data.ByteString as B
import qualified Data.Map.Strict as M

import Kiln.Error
import Kiln.Eval
import Kiln.Graph
import Kiln.Scheduler
import Kiln.State
import Kiln.Workspace

-- | What to build and on how many workers.
data BuildRequest = BuildRequest
  { brTargets :: [B.ByteString]
    -- ^ empty means the default targets
  , brWorkers :: !Int
  }
  deriving (Eq, Show)

-- | The counts reported after a successful build.
data BuildSummary = BuildSummary
  { bsRan :: !Int
  , bsHit :: !Int
  , bsTime :: !Int
  }
  deriving (Eq, Show)

data BuildOutcome = BuildOutcome
  { boWorkspace :: Workspace
    -- ^ unchanged when configuration failed; otherwise includes the new
    -- outputs and the rewritten @.kiln-state@
  , boEvents :: [Event]
  , boResult :: Either BuildError BuildSummary
  }

-- | Run a build against a workspace. Configuration errors (phases 1–5) leave
-- the workspace untouched; once execution begins @.kiln-state@ is always
-- rewritten, even after an execution error.
build :: Workspace -> BuildRequest -> BuildOutcome
build ws req = case configure of
  Left err -> BuildOutcome ws [] (Left err)
  Right (ix, reach) ->
    let state0 = maybe M.empty (parseState . fileContent) (lookupFile stateFilePath ws)
        r = schedule ix reach (brWorkers req) ws state0
        ws' = insertContent stateFilePath (renderState (srState r)) (srWorkspace r)
        result = case srError r of
          Just e -> Left e
          Nothing -> Right (BuildSummary (srRan r) (srHits r) (srTime r))
     in BuildOutcome ws' (srEvents r) result
  where
    configure = do
      prog <- evalProgram ws
      ix <- buildIndex ws prog
      roots <- requestedTargets ix (brTargets req)
      reach <- reachable ix roots
      pure (ix, reach)
