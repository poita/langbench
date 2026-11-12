-- | The pager: page cache, log overlay, dirty set, page allocation, the free
-- list, transactions, commit, rollback and checkpointing (SPEC §10, §13, §15).
--
-- A 'Db' is a mutable, single-threaded handle.  It never touches the file
-- system: the database file and the log go in as byte strings
-- ('newDb') and come out as byte strings ('dbFileBytes', 'dbLogBytes').
module Tessera.Pager
  ( Db
  , newDb
  , readPage
  , writePage
  , getHeader
  , modifyHeader
  , allocatePage
  , freePage
  , inTransaction
  , beginTxn
  , commitTxn
  , rollbackTxn
  , checkpointDb
  , dbLogSize
  , dbFileBytes
  , dbLogBytes
  ) where

import Control.Monad (when)
import qualified Data.ByteString as BS
import Data.IORef
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Tessera.Constants (pageSize, walLimit)
import Tessera.Page
import Tessera.WAL

-- | A database handle.
data Db = Db
  { dbMain :: !(IORef (IntMap BS.ByteString))
  , dbMainCount :: !(IORef Int)
  , dbOverlay :: !(IORef (IntMap BS.ByteString))
  , dbDirty :: !(IORef (IntMap BS.ByteString))
  , dbHeader :: !(IORef Header)
  , dbInTxn :: !(IORef Bool)
  , dbLogChunks :: !(IORef [BS.ByteString])
  , dbLogSz :: !(IORef Int)
  }

-- | Open a database from the contents of @main.tdb@ and @main.twal@ (either
-- may be absent).  Recovery (SPEC §16) happens here.
newDb :: Maybe BS.ByteString -> Maybe BS.ByteString -> IO Db
newDb mainBytes walBytes = do
  let file = case mainBytes of
        Just b | not (BS.null b) -> b
        _ -> encodeHeader freshHeader
      count = BS.length file `div` pageSize
      pages = IntMap.fromDistinctAscList [(i + 1, BS.take pageSize (BS.drop (i * pageSize) file)) | i <- [0 .. count - 1]]
      Recovery lg committed = maybe (Recovery walHeader []) recover walBytes
      overlay = foldl (\m grp -> foldl (\m' (p, img) -> IntMap.insert p img m') m grp) IntMap.empty committed
      page1 = IntMap.findWithDefault (pages IntMap.! 1) 1 overlay
  Db <$> newIORef pages <*> newIORef count <*> newIORef overlay <*> newIORef IntMap.empty
    <*> newIORef (decodeHeader page1) <*> newIORef False
    <*> newIORef [lg] <*> newIORef (BS.length lg)

-- | Read a page through the dirty set, the log overlay and the main file.
readPage :: Db -> Int -> IO BS.ByteString
readPage db p = do
  dirty <- readIORef (dbDirty db)
  case IntMap.lookup p dirty of
    Just img -> pure img
    Nothing -> do
      ov <- readIORef (dbOverlay db)
      case IntMap.lookup p ov of
        Just img -> pure img
        Nothing -> do
          file <- readIORef (dbMain db)
          pure (IntMap.findWithDefault zeroPage p file)

-- | Write a page image into the open transaction's dirty set.
writePage :: Db -> Int -> BS.ByteString -> IO ()
writePage db p img = modifyIORef' (dbDirty db) (IntMap.insert p img)

-- | The current header (including uncommitted changes).
getHeader :: Db -> IO Header
getHeader = readIORef . dbHeader

-- | Change the header; page 1 is written at commit.
modifyHeader :: Db -> (Header -> Header) -> IO ()
modifyHeader db = modifyIORef' (dbHeader db)

-- | Allocate a page: pop the free list or extend the file (SPEC §10).
allocatePage :: Db -> IO Int
allocatePage db = do
  h <- getHeader db
  if hFreeHead h /= 0
    then do
      let p = hFreeHead h
      img <- readPage db p
      modifyHeader db (\x -> x {hFreeHead = freeNext img, hFreeCount = hFreeCount x - 1})
      pure p
    else do
      let p = hPageCount h + 1
      modifyHeader db (\x -> x {hPageCount = p})
      pure p

-- | Push a page onto the free list.
freePage :: Db -> Int -> IO ()
freePage db p = do
  h <- getHeader db
  writePage db p (encodeFree (hFreeHead h))
  modifyHeader db (\x -> x {hFreeHead = p, hFreeCount = hFreeCount x + 1})

-- | Is an explicit transaction open?
inTransaction :: Db -> IO Bool
inTransaction = readIORef . dbInTxn

-- | Open an explicit transaction.
beginTxn :: Db -> IO ()
beginTxn db = writeIORef (dbInTxn db) True

-- | Commit (SPEC §13.4): returns the transaction id and the number of page
-- frames written.  Runs an automatic checkpoint when the log is large.
commitTxn :: Db -> IO (Int, Int)
commitTxn db = do
  modifyHeader db (\h -> h {hCommitCounter = hCommitCounter h + 1})
  h <- getHeader db
  writePage db 1 (encodeHeader h)
  dirty <- readIORef (dbDirty db)
  let txn = hCommitCounter h
      pages = IntMap.toAscList dirty
      recs = [encodePageRecord txn p img | (p, img) <- pages] ++ [encodeCommitRecord txn (length pages)]
  modifyIORef' (dbLogChunks db) (reverse recs ++)
  modifyIORef' (dbLogSz db) (+ (pageRecordSize * length pages + commitRecordSize))
  modifyIORef' (dbOverlay db) (IntMap.union dirty)
  writeIORef (dbDirty db) IntMap.empty
  writeIORef (dbInTxn db) False
  sz <- readIORef (dbLogSz db)
  when (sz >= walLimit) (() <$ checkpointDb db)
  pure (txn, length pages)

-- | Discard the open transaction's changes, including header changes.
rollbackTxn :: Db -> IO ()
rollbackTxn db = do
  writeIORef (dbDirty db) IntMap.empty
  writeIORef (dbInTxn db) False
  page1 <- readPage db 1
  writeIORef (dbHeader db) (decodeHeader page1)

-- | Copy the log overlay into the main file and empty the log (SPEC §15.6).
-- Returns the number of pages copied.
checkpointDb :: Db -> IO Int
checkpointDb db = do
  ov <- readIORef (dbOverlay db)
  h <- getHeader db
  modifyIORef' (dbMain db) (IntMap.union ov)
  writeIORef (dbMainCount db) (hPageCount h)
  writeIORef (dbOverlay db) IntMap.empty
  writeIORef (dbLogChunks db) [walHeader]
  writeIORef (dbLogSz db) walHeaderSize
  pure (IntMap.size ov)

-- | The log's current size in bytes (SPEC §15.4).
dbLogSize :: Db -> IO Int
dbLogSize = readIORef . dbLogSz

-- | The contents of @main.tdb@ as it stands (checkpointed pages only).
dbFileBytes :: Db -> IO BS.ByteString
dbFileBytes db = do
  file <- readIORef (dbMain db)
  count <- readIORef (dbMainCount db)
  pure (BS.concat [IntMap.findWithDefault zeroPage p file | p <- [1 .. count]])

-- | The contents of @main.twal@ as it stands.
dbLogBytes :: Db -> IO BS.ByteString
dbLogBytes db = BS.concat . reverse <$> readIORef (dbLogChunks db)
