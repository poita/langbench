{-# LANGUAGE OverloadedStrings #-}

-- | The public, typed API of the document store.
--
-- Operations return @'Either' 'ErrorKind' a@; a failing operation changes
-- nothing.  Outside an explicit transaction ('begin'), every write runs in
-- its own implicit transaction and is committed immediately.
--
-- The module is meant to be imported qualified:
--
-- > import qualified Tessera.Store as Store
module Tessera.Store
  ( Store
  , openStore
  , newStore
  , storeFileBytes
  , storeLogBytes
    -- * Documents
  , PutOutcome (..)
  , put
  , get
  , delete
  , update
  , unset
    -- * Queries
  , scan
  , find
    -- * Indexes
  , IndexInfo (..)
  , createIndex
  , dropIndex
  , indexes
    -- * Transactions
  , begin
  , commit
  , rollback
  , checkpoint
  , closeStore
    -- * Statistics
  , Stat (..)
  , stat
  ) where

import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM, forM_, unless, when)
import qualified Data.ByteString as BS
import Data.IORef
import qualified Data.IntMap.Strict as IntMap
import Data.List (sort)
import Data.Maybe (fromMaybe)
import Tessera.BTree
import Tessera.Constants
import Tessera.Error
import Tessera.Index
import Tessera.IndexKey (documentKeyOf, valueKey)
import Tessera.Overflow
import Tessera.Page
import Tessera.Pager
import Tessera.Path
import Tessera.Query
import Tessera.Value

-- | An open store: an in-memory handle on a database file and its log.
type Store = Db

-- | Open a store from the bytes of @main.tdb@ and @main.twal@ (each optional).
-- The log is recovered as SPEC §16 prescribes.  Nothing is read from or
-- written to the file system.
openStore :: Maybe BS.ByteString -> Maybe BS.ByteString -> IO Store
openStore = newDb

-- | A fresh, empty store.
newStore :: IO Store
newStore = newDb Nothing Nothing

-- | The bytes of @main.tdb@ (only checkpointed state lives there).
storeFileBytes :: Store -> IO BS.ByteString
storeFileBytes = dbFileBytes

-- | The bytes of @main.twal@.
storeLogBytes :: Store -> IO BS.ByteString
storeLogBytes = dbLogBytes

-- | Finish with a store: an open explicit transaction is rolled back.
closeStore :: Store -> IO ()
closeStore db = do
  open <- inTransaction db
  when open (rollbackTxn db)

-- | Run a write: inside the open transaction if there is one, otherwise in an
-- implicit transaction that is committed at once.
withTxn :: Db -> IO a -> IO a
withTxn db act = do
  open <- inTransaction db
  if open
    then act
    else do
      r <- try act
      case r of
        Left e -> rollbackTxn db >> throwIO (e :: SomeException)
        Right a -> a <$ commitTxn db

checkKey :: BS.ByteString -> IO ()
checkKey k = when (BS.null k || BS.length k > maxKey) (throwKind BadKey)

-- | Validate a new document: depth, then serialised size.
checkDocument :: Value -> IO BS.ByteString
checkDocument v = do
  when (depth v > maxDepth) (throwKind Depth)
  let bytes = serialize v
  when (BS.length bytes > maxDoc) (throwKind DocTooLarge)
  pure bytes

loadDocument :: Db -> Cell -> IO Value
loadDocument db cell = do
  bytes <- readDocument db cell
  maybe (fail "Tessera: corrupt document") pure (deserialize bytes)

-- | Write a document: primary tree first, then the indexes (SPEC §14.3).
writeDocument :: Db -> [(Int, Slot)] -> BS.ByteString -> Maybe (Cell, Maybe Value) -> Value -> BS.ByteString -> IO ()
writeDocument db slots key existing new bytes = do
  forM_ existing $ \(cell, _) -> freeChain db (cellOverflow cell)
  cell' <- buildCell db key bytes
  insertCell db (primaryTree db) cell'
  when (null existing) (modifyHeader db (\h -> h {hPrimaryCount = hPrimaryCount h + 1}))
  maintainIndexes db slots key (existing >>= snd) new

-- | Whether a 'put' created a new document or replaced one.
data PutOutcome = Created | Replaced
  deriving (Eq, Show)

-- | Store a document under a key.
put :: Store -> BS.ByteString -> Value -> IO (Either ErrorKind PutOutcome)
put db key v = attempt $ do
  checkKey key
  bytes <- checkDocument v
  slots <- liveIndexes db
  checkEntryKeys slots key v
  withTxn db $ do
    mcell <- lookupCell db (primaryTree db) key
    existing <- forM mcell $ \c -> do
      old <- if null slots then pure Nothing else Just <$> loadDocument db c
      pure (c, old)
    writeDocument db slots key existing v bytes
    pure (maybe Created (const Replaced) mcell)

-- | Fetch a document.
get :: Store -> BS.ByteString -> IO (Either ErrorKind Value)
get db key = attempt $ do
  checkKey key
  mcell <- lookupCell db (primaryTree db) key
  maybe (throwKind NotFound) (loadDocument db) mcell

-- | Remove a document.
delete :: Store -> BS.ByteString -> IO (Either ErrorKind ())
delete db key = attempt $ do
  checkKey key
  mcell <- lookupCell db (primaryTree db) key
  cell <- maybe (throwKind NotFound) pure mcell
  slots <- liveIndexes db
  withTxn db $ do
    old <- if null slots then pure Nothing else Just <$> loadDocument db cell
    freeChain db (cellOverflow cell)
    _ <- deleteKey db (primaryTree db) key
    modifyHeader db (\h -> h {hPrimaryCount = hPrimaryCount h - 1})
    forM_ old (removeFromIndexes db slots key)

-- | Set the field at a path, creating intermediate objects as needed.
update :: Store -> BS.ByteString -> Path -> Value -> IO (Either ErrorKind ())
update db key path v = attempt $ do
  checkKey key
  mcell <- lookupCell db (primaryTree db) key
  cell <- maybe (throwKind NotFound) pure mcell
  old <- loadDocument db cell
  new <- either throwKind pure (setAt path v old)
  bytes <- checkDocument new
  slots <- liveIndexes db
  checkEntryKeys slots key new
  withTxn db $ writeDocument db slots key (Just (cell, Just old)) new bytes

-- | Remove the field at a path.
unset :: Store -> BS.ByteString -> Path -> IO (Either ErrorKind ())
unset db key path = attempt $ do
  checkKey key
  mcell <- lookupCell db (primaryTree db) key
  cell <- maybe (throwKind NotFound) pure mcell
  old <- loadDocument db cell
  new <- either throwKind pure (unsetAt path old)
  let bytes = serialize new
  slots <- liveIndexes db
  withTxn db $ writeDocument db slots key (Just (cell, Just old)) new bytes

-- | Range scan over the primary tree.  Documents are only read when the
-- options do not ask for keys only.
scan :: Store -> ScanOptions -> IO (Either ErrorKind [(BS.ByteString, Maybe Value)])
scan db opts = attempt $ do
  acc <- newIORef []
  count <- newIORef (0 :: Int)
  let limit = fromMaybe maxBound (scanLimit opts)
      tree = primaryTree db
      inRange k = maybe True (k <) (scanTo opts)
      visit cell = do
        modifyIORef' acc (cell :)
        modifyIORef' count (+ 1)
        (< limit) <$> readIORef count
  when (limit > 0 && maybe True (\t -> maybe True (< t) (scanFrom opts)) (scanTo opts)) $
    if scanReverse opts
      then foldReverse db tree (scanFrom opts) (scanTo opts) visit
      else
        foldFrom db tree (fromMaybe BS.empty (scanFrom opts)) $ \cell ->
          if inRange (cellKey cell) then visit cell else pure False
  cells <- reverse <$> readIORef acc
  forM cells $ \cell ->
    if scanKeysOnly opts
      then pure (cellKey cell, Nothing)
      else (\v -> (cellKey cell, Just v)) <$> loadDocument db cell

-- | Evaluate a predicate over the store.  Returns the plan used and the
-- matches in ascending key order (SPEC §17).
find :: Store -> Pred -> Maybe Int -> IO (Either ErrorKind (Plan, [(BS.ByteString, Value)]))
find db p mlimit = attempt $ do
  slots <- liveIndexes db
  let limit = fromMaybe maxBound mlimit
      slotOf path = case [s | (s, sl) <- slots, slotPath sl == pathText path] of
        s : _ -> Just s
        [] -> Nothing
      chosen = choosePlan (\path -> slotOf path /= Nothing) p
  case chosen of
    Nothing -> do
      matches <- if limit == 0 then pure [] else scanPlan limit
      pure (PlanScan, matches)
    Just (path, op, v) -> do
      matches <-
        if limit == 0
          then pure []
          else case (slotOf path, valueKey v) of
            (Just s, Just vk) -> do
              keys <- candidates db (indexTree db s) op vk
              fetch limit (sort keys)
            _ -> pure []
      pure (PlanIndex path, matches)
  where
    scanPlan limit = do
      acc <- newIORef []
      count <- newIORef (0 :: Int)
      foldFrom db (primaryTree db) BS.empty $ \cell -> do
        doc <- loadDocument db cell
        if evalPred p doc
          then do
            modifyIORef' acc ((cellKey cell, doc) :)
            modifyIORef' count (+ 1)
            (< limit) <$> readIORef count
          else pure True
      reverse <$> readIORef acc
    fetch limit keys = go limit keys []
      where
        go _ [] acc = pure (reverse acc)
        go n (k : ks) acc = do
          mcell <- lookupCell db (primaryTree db) k
          case mcell of
            Nothing -> go n ks acc
            Just cell -> do
              doc <- loadDocument db cell
              if evalPred p doc
                then if n <= 1 then pure (reverse ((k, doc) : acc)) else go (n - 1) ks ((k, doc) : acc)
                else go n ks acc

-- | Document keys of the index entries in the candidate range of SPEC §17.3.
candidates :: Db -> Tree -> CmpOp -> BS.ByteString -> IO [BS.ByteString]
candidates db tree op vk = do
  acc <- newIORef []
  let keep k = modifyIORef' acc (documentKeyOf k :)
      hasPrefix = BS.isPrefixOf vk
  case op of
    OpEq -> foldFrom db tree vk $ \c ->
      if hasPrefix (cellKey c) then keep (cellKey c) >> pure True else pure False
    OpLt -> foldFrom db tree BS.empty $ \c ->
      if cellKey c < vk then keep (cellKey c) >> pure True else pure False
    OpLe -> foldFrom db tree BS.empty $ \c ->
      if cellKey c < vk || hasPrefix (cellKey c) then keep (cellKey c) >> pure True else pure False
    OpGt -> foldFrom db tree vk $ \c ->
      unless (hasPrefix (cellKey c)) (keep (cellKey c)) >> pure True
    OpGe -> foldFrom db tree vk $ \c -> keep (cellKey c) >> pure True
    OpNe -> pure ()
  readIORef acc

-- | One live index, as reported by 'indexes'.
data IndexInfo = IndexInfo
  { indexSlot :: !Int
  , indexPath :: !BS.ByteString
  -- ^ the path text
  , indexRoot :: !Int
  , indexEntries :: !Int
  }
  deriving (Eq, Show)

-- | Build an index on a path.  Returns the number of entries.
createIndex :: Store -> Path -> IO (Either ErrorKind Int)
createIndex db path = attempt $ do
  h <- getHeader db
  when (any ((== pathText path) . slotPath) (IntMap.elems (hSlots h))) (throwKind IndexExists)
  when (IntMap.size (hSlots h) >= maxIndexes) (throwKind IndexLimit)
  entries <- collectEntries db path
  withTxn db (addIndex db path entries)

-- | Drop the index on a path.  Returns the number of pages freed.
dropIndex :: Store -> Path -> IO (Either ErrorKind Int)
dropIndex db path = attempt $ do
  slots <- liveIndexes db
  case [s | (s, sl) <- slots, slotPath sl == pathText path] of
    [] -> throwKind IndexMissing
    s : _ -> withTxn db (removeIndex db s)

-- | The live indexes in slot order.
indexes :: Store -> IO [IndexInfo]
indexes db = do
  slots <- liveIndexes db
  pure [IndexInfo s (slotPath sl) (slotRoot sl) (slotEntries sl) | (s, sl) <- slots]

-- | Open an explicit transaction.
begin :: Store -> IO (Either ErrorKind ())
begin db = attempt $ do
  open <- inTransaction db
  when open (throwKind TxnActive)
  beginTxn db

-- | Commit the explicit transaction.  Returns the transaction id and the
-- number of page frames written to the log.
commit :: Store -> IO (Either ErrorKind (Int, Int))
commit db = attempt $ do
  open <- inTransaction db
  unless open (throwKind NoTxn)
  commitTxn db

-- | Roll back the explicit transaction.
rollback :: Store -> IO (Either ErrorKind ())
rollback db = attempt $ do
  open <- inTransaction db
  unless open (throwKind NoTxn)
  rollbackTxn db

-- | Copy the log into the main file.  Returns the number of pages copied.
checkpoint :: Store -> IO (Either ErrorKind Int)
checkpoint db = attempt $ do
  open <- inTransaction db
  when open (throwKind TxnActive)
  checkpointDb db

-- | The numbers printed by the @stat@ command.
data Stat = Stat
  { statPages :: !Int
  , statFree :: !Int
  , statFreeHead :: !Int
  , statDocs :: !Int
  , statRoot :: !Int
  , statHeight :: !Int
  , statCommits :: !Int
  , statIndexes :: !Int
  , statWal :: !Int
  }
  deriving (Eq, Show)

-- | Current statistics, including uncommitted changes of an open transaction.
stat :: Store -> IO Stat
stat db = do
  h <- getHeader db
  ht <- treeHeight db (primaryTree db)
  wal <- dbLogSize db
  pure
    Stat
      { statPages = hPageCount h
      , statFree = hFreeCount h
      , statFreeHead = hFreeHead h
      , statDocs = hPrimaryCount h
      , statRoot = hPrimaryRoot h
      , statHeight = ht
      , statCommits = hCommitCounter h
      , statIndexes = IntMap.size (hSlots h)
      , statWal = wal
      }
