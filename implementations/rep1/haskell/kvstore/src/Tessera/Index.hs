{-# LANGUAGE OverloadedStrings #-}

-- | Secondary index maintenance (SPEC §14): entries are kept exact by every
-- write, built by @create index@ and freed by @drop index@.
module Tessera.Index
  ( liveIndexes
  , entryFor
  , checkEntryKeys
  , maintainIndexes
  , removeFromIndexes
  , collectEntries
  , addIndex
  , removeIndex
  ) where

import Control.Monad (forM_, when)
import qualified Data.ByteString as BS
import Data.IORef
import qualified Data.IntMap.Strict as IntMap
import Data.Maybe (fromMaybe)
import Tessera.BTree
import Tessera.Constants
import Tessera.Error
import Tessera.IndexKey (entryKey)
import Tessera.Overflow (readDocument)
import Tessera.Page
import Tessera.Pager
import Tessera.Path
import Tessera.Value

-- | The live indexes in slot order.
liveIndexes :: Db -> IO [(Int, Slot)]
liveIndexes db = IntMap.toAscList . hSlots <$> getHeader db

-- | The index entry key a document has in an index, if it is indexable there.
entryFor :: Slot -> BS.ByteString -> Value -> Maybe BS.ByteString
entryFor slot docKey doc = do
  path <- either (const Nothing) Just (parsePath (slotPath slot))
  x <- resolve path doc
  entryKey x docKey

-- | Fail with @index-key-too-long@ if any live index would get an oversized
-- entry for this document.
checkEntryKeys :: [(Int, Slot)] -> BS.ByteString -> Value -> IO ()
checkEntryKeys slots docKey doc =
  forM_ slots $ \(_, slot) -> case entryFor slot docKey doc of
    Just k | BS.length k > maxIndexKey -> throwKind IndexKeyTooLong
    _ -> pure ()

bumpEntries :: Db -> Int -> Int -> IO ()
bumpEntries db s d =
  modifyHeader db (\h -> h {hSlots = IntMap.adjust (\sl -> sl {slotEntries = slotEntries sl + d}) s (hSlots h)})

-- | Bring every live index in line with a document that changed from @old@
-- (if it existed) to @new@, in slot order (SPEC §14.3).
maintainIndexes :: Db -> [(Int, Slot)] -> BS.ByteString -> Maybe Value -> Value -> IO ()
maintainIndexes db slots key old new =
  forM_ slots $ \(s, slot) -> do
    let o = old >>= entryFor slot key
        w = entryFor slot key new
        tree = indexTree db s
    case (o, w) of
      (Nothing, Nothing) -> pure ()
      (Nothing, Just wk) -> insertCell db tree (indexCell wk) >> bumpEntries db s 1
      (Just ok, Nothing) -> deleteKey db tree ok >> bumpEntries db s (-1)
      (Just ok, Just wk)
        | ok == wk -> pure ()
        | otherwise -> deleteKey db tree ok >> insertCell db tree (indexCell wk)

-- | Remove a deleted document's entries from every live index.
removeFromIndexes :: Db -> [(Int, Slot)] -> BS.ByteString -> Value -> IO ()
removeFromIndexes db slots key old =
  forM_ slots $ \(s, slot) -> case entryFor slot key old of
    Nothing -> pure ()
    Just ok -> deleteKey db (indexTree db s) ok >> bumpEntries db s (-1)

-- | Walk the primary tree once, in key order, and compute the index key of
-- every indexable document for a would-be index on @path@.  Fails with
-- @index-key-too-long@ if one is oversized.
collectEntries :: Db -> Path -> IO [BS.ByteString]
collectEntries db path = do
  acc <- newIORef []
  let slot = Slot (pathText path) 0 0
  foldFrom db (primaryTree db) BS.empty $ \cell -> do
    bytes <- readDocument db cell
    let doc = fromMaybe VNull (deserialize bytes)
    case entryFor slot (cellKey cell) doc of
      Nothing -> pure ()
      Just k -> do
        when (BS.length k > maxIndexKey) (throwKind IndexKeyTooLong)
        modifyIORef' acc (k :)
    pure True
  reverse <$> readIORef acc

-- | Claim the lowest unused slot and insert the entries in the given order.
-- Returns the number of entries.
addIndex :: Db -> Path -> [BS.ByteString] -> IO Int
addIndex db path entries = do
  h <- getHeader db
  let s = length (takeWhile (`IntMap.member` hSlots h) [0 ..])
  modifyHeader db (\x -> x {hSlots = IntMap.insert s (Slot (pathText path) 0 0) (hSlots x)})
  let tree = indexTree db s
  forM_ entries $ \k -> insertCell db tree (indexCell k) >> bumpEntries db s 1
  pure (length entries)

-- | Free every page of an index in post-order and clear its slot.  Returns
-- the number of pages freed.
removeIndex :: Db -> Int -> IO Int
removeIndex db s = do
  h <- getHeader db
  let root = maybe 0 slotRoot (IntMap.lookup s (hSlots h))
  pages <- postOrderPages db root
  mapM_ (freePage db) pages
  modifyHeader db (\x -> x {hSlots = IntMap.delete s (hSlots x)})
  pure (length pages)
