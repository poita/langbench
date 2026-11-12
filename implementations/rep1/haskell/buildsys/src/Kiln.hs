-- | Kiln: a deterministic, incremental build-system simulator.
--
-- A /session/ (see "Kiln.Session") is a script of builds and workspace
-- mutations.  Each build evaluates the workspace's @main.kiln@ ("Kiln.Eval"),
-- validates the resulting graph ("Kiln.Graph"), decides freshness from the
-- @.kiln-state@ file ("Kiln.State") and simulates parallel execution
-- ("Kiln.Scheduler") of the sixteen built-in commands ("Kiln.Command").
--
-- The usual entry points are 'runDirectory', which implements the command-line
-- contract, and 'runSession' for in-memory use:
--
-- > import qualified Kiln
-- > import qualified Kiln.Workspace as W
-- >
-- > main = do
-- >   let ws = W.fromList [("main.kiln", "step {\n out \"out/a.txt\"\n cmd write(\"A\\n\")\n}\ndefault \"out/a.txt\"\n")]
-- >   (final, logText) <- Kiln.runSession ws (Kiln.parseSession "build\nbuild\n")
-- >   print logText
module Kiln
  ( -- * Running sessions
    runDirectory
  , runSession
  , parseSession
  , SessionStep (..)
    -- * Builds
  , runBuild
  , BuildResult (..)
    -- * Workspaces
  , Workspace
  , loadWorkspace
  , writeWorkspace
    -- * Errors
  , KilnError (..)
  , renderError
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

import Kiln.Build
import Kiln.Error
import Kiln.Session
import Kiln.Workspace (Workspace, loadWorkspace, writeWorkspace)

-- | Implement the I/O contract: read @session.txt@ and the initial workspace
-- from the input directory; write @log.txt@ and @workspace/@ into the output
-- directory.
runDirectory :: FilePath -> FilePath -> IO ()
runDirectory input output = do
  ws0 <- loadWorkspace input
  script <- BS.readFile (input </> "session.txt")
  (ws, logText) <- runSession ws0 (parseSession script)
  createDirectoryIfMissing True output
  BL.writeFile (output </> "log.txt") logText
  writeWorkspace (output </> "workspace") ws
