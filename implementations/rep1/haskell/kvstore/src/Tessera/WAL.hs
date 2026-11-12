{-# LANGUAGE OverloadedStrings #-}

-- | The write-ahead log format (SPEC §15) and its recovery scan (SPEC §16).
module Tessera.WAL
  ( walHeader
  , walHeaderSize
  , pageRecordSize
  , commitRecordSize
  , encodePageRecord
  , encodeCommitRecord
  , Recovery (..)
  , recover
  ) where

import qualified Data.ByteString as BS
import Data.ByteString.Builder
import qualified Data.ByteString.Lazy as LBS
import Tessera.Binary
import Tessera.CRC (crc32, crc32Chunks)

strictly :: Builder -> BS.ByteString
strictly = LBS.toStrict . toLazyByteString

-- | The 32-byte log header (SPEC §15.1).
walHeader :: BS.ByteString
walHeader = body <> strictly (word32BE (crc32 body))
  where
    body = strictly (byteString "TESSWAL1" <> w16 1 <> w16 1024 <> zeros 16)

-- | Size of the log header in bytes.
walHeaderSize :: Int
walHeaderSize = 32

-- | Bytes of a page image record.
pageRecordSize :: Int
pageRecordSize = 1048

-- | Bytes of a commit record.
commitRecordSize :: Int
commitRecordSize = 24

record :: Int -> Int -> Int -> Int -> BS.ByteString -> BS.ByteString
record ty txn field plen payload = strictly (byteString hdr <> word32BE (crc32Chunks [hdr, payload]) <> byteString payload)
  where
    hdr = strictly (word8 (fromIntegral ty) <> zeros 3 <> word64BE (fromIntegral txn) <> w32 field <> w32 plen)

-- | A page image record for transaction @txn@.
encodePageRecord :: Int -> Int -> BS.ByteString -> BS.ByteString
encodePageRecord txn pageNo payload = record 1 txn pageNo 1024 payload

-- | A commit record for transaction @txn@ with @frames@ page images.
encodeCommitRecord :: Int -> Int -> BS.ByteString
encodeCommitRecord txn frames = record 2 txn frames 0 BS.empty

-- | The outcome of scanning an input log.
data Recovery = Recovery
  { recLog :: BS.ByteString
  -- ^ the log the engine continues with: the valid prefix, or a fresh header
  , recCommitted :: [[(Int, BS.ByteString)]]
  -- ^ the page images of each committed transaction, in log order
  }

-- | Validate the header and scan for committed transactions (SPEC §16.2–§16.4).
recover :: BS.ByteString -> Recovery
recover input
  | not headerOk = Recovery walHeader []
  | otherwise = go 32 Nothing 32 []
  where
    headerOk =
      BS.length input >= 32
        && BS.take 12 input == BS.take 12 walHeader
        && BS.all (== 0) (BS.take 16 (BS.drop 12 input))
        && be32 input 28 == fromIntegral (crc32 (BS.take 28 input))
    total = BS.length input
    finish validEnd done = Recovery (BS.take validEnd input) (reverse done)
    go off grp validEnd done
      | rem' < 24 = finish validEnd done
      | not wellFormed = finish validEnd done
      | ty == 1 = case grp of
          Just (t, _) | t /= txn -> finish validEnd done
          Just (t, imgs) -> go (off + 24 + 1024) (Just (t, (field, payload) : imgs)) validEnd done
          Nothing -> go (off + 24 + 1024) (Just (txn, [(field, payload)])) validEnd done
      | otherwise = case grp of
          Just (t, imgs)
            | t == txn && length imgs == field ->
                go (off + 24) Nothing (off + 24) (reverse imgs : done)
          _ -> finish validEnd done
      where
        rem' = total - off
        hdr = BS.take 20 (BS.drop off input)
        ty = fromIntegral (BS.index input off) :: Int
        txn = fromIntegral (be64 input (off + 4)) :: Int
        field = be32 input (off + 12)
        plen = be32 input (off + 16)
        payload = BS.take plen (BS.drop (off + 24) input)
        wellFormed =
          (ty == 1 || ty == 2)
            && BS.all (== 0) (BS.take 3 (BS.drop (off + 1) input))
            && plen == (if ty == 1 then 1024 else 0)
            && field >= 1
            && rem' >= 24 + plen
            && be32 input (off + 20) == fromIntegral (crc32Chunks [hdr, payload])
