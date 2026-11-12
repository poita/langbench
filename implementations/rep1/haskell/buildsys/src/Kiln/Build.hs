-- | One @build@: configuration (evaluate, validate, resolve, cycle check)
-- followed by scheduling and the state-file update.
module Kiln.Build
  ( BuildResult (..)
  , runBuild
  ) where

import qualified Data.ByteString as BS

import Kiln.Error
import Kiln.Eval (evaluateBuild)
import Kiln.Graph
import Kiln.Path (buildFilePath, stateFilePath)
import Kiln.Scheduler
import Kiln.State
import Kiln.Workspace (Workspace)
import qualified Kiln.Workspace as Workspace

-- | The outcome of a build: the new workspace, the events to log and either
-- the error or the summary.
data BuildResult = BuildResult
  { brWorkspace :: Workspace
  , brEvents :: [Event]
  , brOutcome :: Either KilnError Stats
  }

-- | Run a build with the given requested targets (empty for the defaults) on
-- the given number of workers.  A configuration error leaves the workspace
-- untouched; an execution error still updates @.kiln-state@.
runBuild :: Workspace -> [BS.ByteString] -> Int -> IO BuildResult
runBuild ws targets workers
  | not (Workspace.member buildFilePath ws) = pure (configError ENoBuildFile)
  | otherwise = do
      evaluated <- evaluateBuild ws
      pure $ case evaluated of
        Left e -> configError e
        Right decls -> case configure decls of
          Left e -> configError e
          Right (g, reach) ->
            let state0 = maybe mempty parseState (Workspace.lookupContent stateFilePath ws)
                result = schedule g reach workers ws state0
                ws' = Workspace.insert stateFilePath (renderState (srState result)) (srWorkspace result)
             in BuildResult ws' (srEvents result) (srOutcome result)
  where
    configError e = BuildResult ws [] (Left e)
    configure decls = do
      g <- buildGraph ws decls
      requested <- resolveRequested g targets
      reach <- either (Left . ECycle . map (nodeName g)) Right (findReachable g requested)
      pure (g, reach)
