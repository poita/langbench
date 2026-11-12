{-# LANGUAGE BangPatterns #-}

-- |
-- Module      : Git.Pack
-- Description : Pack index (version 2) lookup and packfile entry decoding.
module Git.Pack
  ( -- * Index
    PackIndex
  , parseIndex
  , indexCount
  , indexLookup
  , indexIdAt
  , indexOffsetAt
  , HexPrefix
  , mkHexPrefix
  , matchesPrefix
  , prefixLowId
  , indexPrefixMatches
    -- * Packfile
  , PackEntry (..)
  , checkPackHeader
  , readPackEntry
  ) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Unsafe as BU
import Data.Char (toLower)

import Git.Inflate (Inflated (..), zlibDecompressWithHint)
import Git.Types

------------------------------------------------------------------------------
-- Index

-- | A pack index, version 2.  Lookups slice the underlying bytes.
data PackIndex = PackIndex
  { idxBytes :: !ByteString
  , idxCount :: !Int
  }

instance Show PackIndex where
  show ix = "PackIndex <" ++ show (idxCount ix) ++ " objects>"

be32 :: ByteString -> Int -> Int
be32 bs o =
  (fromIntegral (BU.unsafeIndex bs o) `shiftL` 24)
    .|. (fromIntegral (BU.unsafeIndex bs (o + 1)) `shiftL` 16)
    .|. (fromIntegral (BU.unsafeIndex bs (o + 2)) `shiftL` 8)
    .|. fromIntegral (BU.unsafeIndex bs (o + 3))

-- | Validate the header and sizes of a @.idx@ file.
parseIndex :: ByteString -> Either String PackIndex
parseIndex bs
  | BS.length bs < 1032 + 40 = Left "pack index too short"
  | BS.take 8 bs /= BS.pack [0xff, 0x74, 0x4f, 0x63, 0, 0, 0, 2] = Left "not a version 2 pack index"
  | BS.length bs < 1032 + 28 * n + 40 = Left "pack index truncated"
  | otherwise = Right (PackIndex bs n)
  where
    n = be32 bs (8 + 4 * 255)

-- | Number of objects in the index (@fanout[255]@).
indexCount :: PackIndex -> Int
indexCount = idxCount

fanout :: PackIndex -> Int -> Int
fanout ix b = be32 (idxBytes ix) (8 + 4 * b)

idAtRaw :: PackIndex -> Int -> ByteString
idAtRaw ix i = BU.unsafeTake 20 (BU.unsafeDrop (1032 + 20 * i) (idxBytes ix))

-- | The id at a position of the sorted id table.
indexIdAt :: PackIndex -> Int -> ObjectId
indexIdAt ix i = case objectIdFromBytes (idAtRaw ix i) of
  Just o -> o
  Nothing -> error "indexIdAt: impossible"

-- | Binary search for an id, inside its fanout bucket.  Returns the position.
indexLookup :: PackIndex -> ObjectId -> Maybe Int
indexLookup ix oid = go lo0 hi0
  where
    raw = objectIdBytes oid
    first = fromIntegral (BS.head raw) :: Int
    lo0 = if first == 0 then 0 else fanout ix (first - 1)
    hi0 = fanout ix first
    go !lo !hi
      | lo >= hi = Nothing
      | otherwise =
          let mid = (lo + hi) `div` 2
           in case compare (idAtRaw ix mid) raw of
                EQ -> Just mid
                LT -> go (mid + 1) hi
                GT -> go lo mid

-- | The packfile offset of the object at a position, or 'Nothing' if the
-- 64-bit offset table does not cover it.
indexOffsetAt :: PackIndex -> Int -> Maybe Int
indexOffsetAt ix i
  | v .&. 0x80000000 == 0 = Just v
  | pos + 8 <= BS.length bs - 40 =
      let hi = be32 bs pos
          lo = be32 bs (pos + 4)
       in if hi >= 0x80000000 then Nothing else Just ((hi `shiftL` 32) .|. lo)
  | otherwise = Nothing
  where
    bs = idxBytes ix
    n = idxCount ix
    v = be32 bs (1032 + 20 * n + 4 * n + 4 * i)
    pos = 1032 + 28 * n + 8 * (v .&. 0x7fffffff)

-- | A prefix of 1 to 40 hexadecimal digits.
data HexPrefix = HexPrefix
  { _prefixNibbles :: !Int
  , prefixLow :: !ByteString
    -- ^ the digits padded with zeros to 20 bytes
  }

-- | Parse a hexadecimal prefix (either case, 1 to 40 digits).
mkHexPrefix :: ByteString -> Maybe HexPrefix
mkHexPrefix h
  | n < 1 || n > 40 = Nothing
  | otherwise = do
      oid <- objectIdFromHex (BC.map toLower h <> BC.replicate (40 - n) '0')
      pure (HexPrefix n (objectIdBytes oid))
  where
    n = BS.length h

-- | The smallest id that starts with the prefix.
prefixLowId :: HexPrefix -> ObjectId
prefixLowId p = case objectIdFromBytes (prefixLow p) of
  Just o -> o
  Nothing -> error "prefixLowId: impossible"

-- | Does the id start with the prefix?
matchesPrefix :: HexPrefix -> ObjectId -> Bool
matchesPrefix (HexPrefix n low) oid =
  BS.take full raw == BS.take full low
    && (even n || (BS.index raw full `shiftR` 4) == (BS.index low full `shiftR` 4))
  where
    raw = objectIdBytes oid
    full = n `div` 2

-- | Up to the first @limit@ ids of the index that start with the prefix.
indexPrefixMatches :: Int -> PackIndex -> HexPrefix -> [ObjectId]
indexPrefixMatches limit ix p = take limit (takeWhile (matchesPrefix p) (map (indexIdAt ix) [start .. idxCount ix - 1]))
  where
    start = lowerBound 0 (idxCount ix)
    lowerBound !lo !hi
      | lo >= hi = lo
      | otherwise =
          let mid = (lo + hi) `div` 2
           in if idAtRaw ix mid < prefixLow p then lowerBound (mid + 1) hi else lowerBound lo mid

------------------------------------------------------------------------------
-- Packfile

-- | One decoded packfile entry.
data PackEntry
  = PackObject ObjectType ByteString
    -- ^ a whole object
  | OfsDelta Int ByteString
    -- ^ a delta whose base is at the given absolute offset in the same pack
  | RefDelta ObjectId ByteString
    -- ^ a delta whose base is named by id and may live anywhere
  deriving (Eq, Show)

-- | Check the @PACK@ signature and version 2 of a @.pack@ file.
checkPackHeader :: ByteString -> Bool
checkPackHeader bs = BS.length bs >= 32 && BS.take 8 bs == BC.pack "PACK" <> BS.pack [0, 0, 0, 2]

-- | Decode the entry starting at an offset of the pack.
readPackEntry :: ByteString -> Int -> Either String PackEntry
readPackEntry pack off
  | off < 12 || off >= BS.length pack - 20 = Left "pack offset out of range"
  | otherwise = do
      let b0 = fromIntegral (BU.unsafeIndex pack off) :: Int
          ty = (b0 `shiftR` 4) .&. 7
      (size, p1) <- sizeVarint b0 (off + 1) 4
      case ty of
        6 -> do
          (v, p2) <- ofsVarint p1
          let base = off - v
          if v <= 0 || base < 12 then Left "bad OFS_DELTA base" else OfsDelta base <$> inflateAt size p2
        7 ->
          if p1 + 20 > BS.length pack
            then Left "truncated REF_DELTA"
            else do
              oid <- maybe (Left "bad id") Right (objectIdFromBytes (BS.take 20 (BS.drop p1 pack)))
              RefDelta oid <$> inflateAt size (p1 + 20)
        1 -> PackObject TCommit <$> inflateAt size p1
        2 -> PackObject TTree <$> inflateAt size p1
        3 -> PackObject TBlob <$> inflateAt size p1
        4 -> PackObject TTag <$> inflateAt size p1
        _ -> Left "invalid pack object type"
  where
    len = BS.length pack
    sizeVarint b0 p0 sh0 = go b0 p0 sh0 (b0 .&. 15)
      where
        go !c !q !sh !acc
          | c < 128 = Right (acc, q)
          | q >= len = Left "truncated pack header"
          | otherwise =
              let c' = fromIntegral (BU.unsafeIndex pack q) :: Int
               in go c' (q + 1) (sh + 7) (acc .|. ((c' .&. 0x7f) `shiftL` sh))
    ofsVarint p
      | p >= len = Left "truncated OFS_DELTA"
      | otherwise =
          let c = fromIntegral (BU.unsafeIndex pack p) :: Int
           in go c (p + 1) (c .&. 0x7f)
      where
        go !c !q !v
          | c < 128 = Right (v, q)
          | q >= len = Left "truncated OFS_DELTA"
          | otherwise =
              let c' = fromIntegral (BU.unsafeIndex pack q) :: Int
               in go c' (q + 1) (((v + 1) `shiftL` 7) .|. (c' .&. 0x7f))
    inflateAt size p = case zlibDecompressWithHint (min size (1 `shiftL` 26)) (BS.drop p pack) of
      Left e -> Left (show e)
      Right r -> Right (inflatedBytes r)
