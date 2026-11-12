-- |
-- Module      : Git.Types
-- Description : Object ids, object types and the error type shared by the library.
module Git.Types
  ( -- * Object ids
    ObjectId
  , objectIdBytes
  , objectIdFromBytes
  , objectIdFromHex
  , objectIdToHex
  , zeroObjectId
    -- * Object types
  , ObjectType (..)
  , objectTypeName
  , parseObjectType
    -- * Errors
  , GitError (..)
  , failWith
  ) where

import Control.Exception (Exception, throwIO)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Word (Word8)

-- | A 20-byte SHA-1 object id.  The 'Ord' instance compares the raw bytes,
-- which is the order of ids in a pack index.
newtype ObjectId = ObjectId ByteString
  deriving (Eq, Ord)

instance Show ObjectId where
  show = BC.unpack . objectIdToHex

-- | The raw 20 bytes of an id.
objectIdBytes :: ObjectId -> ByteString
objectIdBytes (ObjectId b) = b

-- | Build an id from exactly 20 raw bytes.
objectIdFromBytes :: ByteString -> Maybe ObjectId
objectIdFromBytes b
  | BS.length b == 20 = Just (ObjectId b)
  | otherwise = Nothing

-- | The all-zero id (used by @diff@ for an absent side).
zeroObjectId :: ObjectId
zeroObjectId = ObjectId (BS.replicate 20 0)

-- | Parse exactly 40 hexadecimal digits (either case).
objectIdFromHex :: ByteString -> Maybe ObjectId
objectIdFromHex h
  | BS.length h /= 40 = Nothing
  | otherwise = ObjectId . BS.pack <$> pairs (BS.unpack h)
  where
    pairs (a : b : rest) = do
      x <- hexVal a
      y <- hexVal b
      (fromIntegral (x * 16 + y) :) <$> pairs rest
    pairs [] = Just []
    pairs _ = Nothing

hexVal :: Word8 -> Maybe Int
hexVal c
  | c >= 48 && c <= 57 = Just (fromIntegral c - 48)
  | c >= 97 && c <= 102 = Just (fromIntegral c - 87)
  | c >= 65 && c <= 70 = Just (fromIntegral c - 55)
  | otherwise = Nothing

-- | The 40 lowercase hexadecimal digits of an id.
objectIdToHex :: ObjectId -> ByteString
objectIdToHex (ObjectId b) = BS.concatMap digits b
  where
    digits w = BS.pack [digit (w `div` 16), digit (w `mod` 16)]
    digit n = if n < 10 then 48 + n else 87 + n

-- | The four kinds of git object.
data ObjectType = TCommit | TTree | TBlob | TTag
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | @commit@, @tree@, @blob@ or @tag@.
objectTypeName :: ObjectType -> ByteString
objectTypeName TCommit = BC.pack "commit"
objectTypeName TTree = BC.pack "tree"
objectTypeName TBlob = BC.pack "blob"
objectTypeName TTag = BC.pack "tag"

-- | Inverse of 'objectTypeName'.
parseObjectType :: ByteString -> Maybe ObjectType
parseObjectType s = lookup s [(objectTypeName t, t) | t <- [minBound .. maxBound]]

-- | Everything that can make a query fail.  The library throws these as
-- exceptions from its 'IO' functions; use 'Control.Exception.try' to catch
-- them.
data GitError
  = ObjectNotFound ObjectId
    -- ^ no loose file or pack entry has this id
  | DamagedObject String
    -- ^ an object (or the pack holding it) could not be decoded
  | BadRevision String
    -- ^ a revision did not resolve or did not peel as asked
  | BadCommand String
    -- ^ a command line was malformed
  deriving (Eq, Show)

instance Exception GitError

-- | Throw a 'GitError'.
failWith :: GitError -> IO a
failWith = throwIO
