-- |
-- Module      : Git
-- Description : Read a git repository straight off disk.
--
-- The whole stack is implemented here, without @git@, zlib or any hashing
-- library: SHA-1 ("Git.SHA1"), DEFLATE ("Git.Inflate"), delta decoding
-- ("Git.Delta"), pack indexes and packfiles ("Git.Pack"), the object store
-- ("Git.Store"), refs ("Git.Ref"), revisions ("Git.Revision") and the
-- queries ("Git.Query").
--
-- > import Git
-- > main = do
-- >   repo <- openRepository ".git"
-- >   oid  <- resolveRevision repo (BC.pack "main~2")
-- >   out  <- logHistory repo (objectIdToHex oid) (Just 5)
-- >   BC.putStr out
module Git
  ( module Git.Types
  , module Git.Object
  , module Git.Store
  , module Git.Revision
  , module Git.Query
  , module Git.Command
  , module Git.Batch
  ) where

import Git.Batch
import Git.Command
import Git.Object
import Git.Query
import Git.Revision
import Git.Store
import Git.Types
