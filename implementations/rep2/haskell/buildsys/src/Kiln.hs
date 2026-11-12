-- | Kiln, an incremental build system simulator.
--
-- This module re-exports the high-level API. A typical use is to build a
-- 'Workspace', run one or more builds with 'build', or run a whole scripted
-- session with 'runSession'.
--
-- > import qualified Data.ByteString.Char8 as BC
-- > import Kiln
-- >
-- > main :: IO ()
-- > main = do
-- >   let ws = fromFiles [("main.kiln", BC.pack "step { out \"out/a.txt\"\n cmd write(\"hi\\n\") }\n...")]
-- >       out = build ws (BuildRequest ["out/a.txt"] 2)
-- >   print (either renderError (const "ok") (boResult out))
module Kiln
  ( -- * Workspaces
    module Kiln.Workspace
    -- * Building
  , module Kiln.Build
  , Event (..)
  , EventKind (..)
  , BuildError
  , renderError
    -- * Sessions
  , module Kiln.Session
    -- * Hashing
  , fnv1a
  , renderHash
  ) where

import Kiln.Build
import Kiln.Error (BuildError, renderError)
import Kiln.Hash (fnv1a, renderHash)
import Kiln.Scheduler (Event (..), EventKind (..))
import Kiln.Session
import Kiln.Workspace
