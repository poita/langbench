{-# LANGUAGE OverloadedStrings #-}

-- | Overflow chains for documents longer than 192 bytes (SPEC §9).
module Tessera.Overflow
  ( buildCell
  , readDocument
  , freeChain
  ) where

import Control.Monad (forM_, zipWithM_)
import qualified Data.ByteString as BS
import Data.ByteString.Builder
import qualified Data.ByteString.Lazy as LBS
import Tessera.Binary
import Tessera.Constants
import Tessera.Page
import Tessera.Pager

-- | Build the primary leaf cell for a document, allocating and writing its
-- overflow chain (first chunk first) before the caller inserts the cell.
buildCell :: Db -> BS.ByteString -> BS.ByteString -> IO Cell
buildCell db key doc
  | BS.length doc <= maxInline = pure (Cell key (BS.length doc) doc 0)
  | otherwise = do
      let (inline, rest) = BS.splitAt maxInline doc
          chunks = chunksOf ovfPayload rest
      pages <- mapM (const (allocatePage db)) chunks
      let nexts = drop 1 pages ++ [0]
      zipWithM_ (\(p, n) chunk -> writePage db p (encodeOverflow n chunk)) (zip pages nexts) chunks
      pure (Cell key (BS.length doc) inline (case pages of p : _ -> p; [] -> 0))

chunksOf :: Int -> BS.ByteString -> [BS.ByteString]
chunksOf n bs
  | BS.null bs = []
  | otherwise = let (a, b) = BS.splitAt n bs in a : chunksOf n b

encodeOverflow :: Int -> BS.ByteString -> BS.ByteString
encodeOverflow next chunk =
  LBS.toStrict . toLazyByteString $
    word8 3 <> zeros 3 <> w32 next <> w16 (BS.length chunk) <> zeros 2
      <> byteString chunk <> zeros (ovfPayload - BS.length chunk)

-- | The complete serialised document of a cell.
readDocument :: Db -> Cell -> IO BS.ByteString
readDocument db cell
  | cellOverflow cell == 0 = pure (cellInline cell)
  | otherwise = do
      rest <- go (cellOverflow cell)
      pure (BS.concat (cellInline cell : rest))
  where
    go 0 = pure []
    go p = do
      img <- readPage db p
      let chunk = BS.take (be16 img 8) (BS.drop 12 img)
      (chunk :) <$> go (be32 img 4)

-- | Free an overflow chain, first page first (so the last page ends up at the
-- head of the free list).  A chain of @0@ is empty.
freeChain :: Db -> Int -> IO ()
freeChain db first = do
  pages <- walk first
  forM_ pages (freePage db)
  where
    walk 0 = pure []
    walk p = do
      img <- readPage db p
      (p :) <$> walk (be32 img 4)
