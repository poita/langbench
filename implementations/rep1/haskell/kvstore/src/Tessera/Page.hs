{-# LANGUAGE OverloadedStrings #-}

-- | Canonical page images (SPEC §7–§11): the header page, free pages, and
-- B+tree pages.  Every page is a pure function of its logical content, so
-- re-encoding a decoded page reproduces its bytes.
module Tessera.Page
  ( -- * Header page
    Header (..)
  , Slot (..)
  , freshHeader
  , encodeHeader
  , decodeHeader
    -- * Free pages
  , encodeFree
  , freeNext
    -- * B+tree pages
  , LeafKind (..)
  , Cell (..)
  , Node (..)
  , indexCell
  , nodeUsed
  , nodeCosts
  , encodeNode
  , decodeNode
  , zeroPage
  ) where

import qualified Data.ByteString as BS
import Data.ByteString.Builder
import qualified Data.ByteString.Lazy as LBS
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.List (scanl')
import Tessera.Binary
import Tessera.Constants

strictly :: Builder -> BS.ByteString
strictly = LBS.toStrict . toLazyByteString

-- | A page of 1024 zero bytes.
zeroPage :: BS.ByteString
zeroPage = BS.replicate pageSize 0

-- | One live slot of the index directory (SPEC §8).
data Slot = Slot
  { slotPath :: !BS.ByteString
  , slotRoot :: !Int
  , slotEntries :: !Int
  }
  deriving (Eq, Show)

-- | The contents of page 1 (SPEC §7.2).
data Header = Header
  { hPageCount :: !Int
  , hFreeHead :: !Int
  , hFreeCount :: !Int
  , hPrimaryRoot :: !Int
  , hPrimaryCount :: !Int
  , hCommitCounter :: !Int
  , hSlots :: !(IntMap Slot)
  -- ^ live slots by slot number
  }
  deriving (Eq, Show)

-- | The header of a fresh database (SPEC §7.3).
freshHeader :: Header
freshHeader = Header 1 0 0 0 0 0 IntMap.empty

encodeHeader :: Header -> BS.ByteString
encodeHeader h =
  strictly $
    byteString "TESSERA1" <> w16 1 <> w16 pageSize
      <> w32 (hPageCount h) <> w32 (hFreeHead h) <> w32 (hFreeCount h)
      <> w32 (hPrimaryRoot h) <> w32 (hPrimaryCount h)
      <> word64BE (fromIntegral (hCommitCounter h))
      <> w32 (IntMap.size (hSlots h))
      <> zeros 84
      <> mconcat [slot (IntMap.lookup s (hSlots h)) | s <- [0 .. maxIndexes - 1]]
      <> zeros 128
  where
    slot Nothing = zeros 48
    slot (Just (Slot p r e)) =
      word8 1 <> word8 (fromIntegral (BS.length p)) <> byteString p
        <> zeros (30 - BS.length p) <> w32 r <> w32 e <> zeros 8

-- | Decode page 1.  The page is assumed well formed.
decodeHeader :: BS.ByteString -> Header
decodeHeader bs =
  Header
    { hPageCount = be32 bs 12
    , hFreeHead = be32 bs 16
    , hFreeCount = be32 bs 20
    , hPrimaryRoot = be32 bs 24
    , hPrimaryCount = be32 bs 28
    , hCommitCounter = fromIntegral (be64 bs 32)
    , hSlots = IntMap.fromList [(s, slot (128 + 48 * s)) | s <- [0 .. maxIndexes - 1], BS.index bs (128 + 48 * s) == 1]
    }
  where
    slot o = Slot (BS.take (fromIntegral (BS.index bs (o + 1))) (BS.drop (o + 2) bs)) (be32 bs (o + 32)) (be32 bs (o + 36))

-- | A free page whose successor is the given page (SPEC §10).
encodeFree :: Int -> BS.ByteString
encodeFree next = strictly (word8 0 <> zeros 3 <> w32 next <> zeros 1016)

-- | The @next@ field of a free page.
freeNext :: BS.ByteString -> Int
freeNext bs = be32 bs 4

-- | Which kind of leaf a tree uses.
data LeafKind = PrimaryLeaf | IndexLeaf
  deriving (Eq, Show)

-- | A leaf cell.  Index leaves use only 'cellKey'.
data Cell = Cell
  { cellKey :: !BS.ByteString
  , cellDocLen :: !Int
  -- ^ total serialised document length (primary leaves)
  , cellInline :: !BS.ByteString
  -- ^ the inline document bytes (primary leaves)
  , cellOverflow :: !Int
  -- ^ first overflow page, or 0
  }
  deriving (Eq, Show)

-- | An index leaf cell holding just a key.
indexCell :: BS.ByteString -> Cell
indexCell k = Cell k 0 BS.empty 0

-- | The logical content of a B+tree page.
data Node
  = Leaf !LeafKind [Cell] !Int
  -- ^ cells and the next-leaf link
  | Interior [(BS.ByteString, Int)] !Int
  -- ^ @(separator, child)@ cells and the rightmost child
  deriving (Eq, Show)

leafCellSize :: LeafKind -> Cell -> Int
leafCellSize PrimaryLeaf c = 12 + BS.length (cellKey c) + BS.length (cellInline c)
leafCellSize IndexLeaf c = 2 + BS.length (cellKey c)

-- | The cost (size plus pointer) of each cell of a node, in order.
nodeCosts :: Node -> [Int]
nodeCosts (Leaf k cs _) = [leafCellSize k c + 2 | c <- cs]
nodeCosts (Interior cs _) = [6 + BS.length key + 2 | (key, _) <- cs]

-- | The payload size @used(page)@ of SPEC §11.2.
nodeUsed :: Node -> Int
nodeUsed = sum . nodeCosts

encodeLeafCell :: LeafKind -> Cell -> BS.ByteString
encodeLeafCell PrimaryLeaf (Cell k dl inl ov) =
  strictly $ w16 (BS.length k) <> w32 dl <> w16 (BS.length inl) <> w32 ov <> byteString k <> byteString inl
encodeLeafCell IndexLeaf (Cell k _ _ _) = strictly (w16 (BS.length k) <> byteString k)

-- | Canonical 1024-byte encoding of a node (SPEC §11.2).  The node must not
-- overflow.
encodeNode :: Node -> BS.ByteString
encodeNode node =
  strictly $
    word8 ty <> word8 0 <> w16 n <> w16 start <> w16 0 <> w32 link <> w32 0
      <> mconcat [w16 o | o <- take n offsets]
      <> zeros (start - (btreeHeader + 2 * n))
      <> mconcat (map byteString encs)
  where
    (ty, encs, link) = case node of
      Leaf k cs nxt -> (if k == PrimaryLeaf then 1 else 5, map (encodeLeafCell k) cs, nxt)
      Interior cs r -> (2, [strictly (w16 (BS.length key) <> w32 child <> byteString key) | (key, child) <- cs], r)
    n = length encs
    total = sum (map BS.length encs)
    start = pageSize - total
    offsets = scanl' (+) start (map BS.length encs)

-- | Decode a B+tree page.
decodeNode :: BS.ByteString -> Node
decodeNode bs = case BS.index bs 0 of
  2 -> Interior [interiorCell (ptr i) | i <- [0 .. n - 1]] link
  1 -> Leaf PrimaryLeaf [primaryCell (ptr i) | i <- [0 .. n - 1]] link
  _ -> Leaf IndexLeaf [indexLeafCell (ptr i) | i <- [0 .. n - 1]] link
  where
    n = be16 bs 2
    link = be32 bs 8
    ptr i = be16 bs (btreeHeader + 2 * i)
    slice o l = BS.take l (BS.drop o bs)
    interiorCell o = let kl = be16 bs o in (slice (o + 6) kl, be32 bs (o + 2))
    primaryCell o =
      let kl = be16 bs o
          il = be16 bs (o + 6)
       in Cell (slice (o + 12) kl) (be32 bs (o + 2)) (slice (o + 12 + kl) il) (be32 bs (o + 8))
    indexLeafCell o = indexCell (slice (o + 2) (be16 bs o))
