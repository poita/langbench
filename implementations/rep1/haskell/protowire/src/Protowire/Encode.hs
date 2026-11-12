{-# LANGUAGE BangPatterns #-}

-- |
-- Module      : Protowire.Encode
-- Description : 'Message' tree to canonical wire bytes.
--
-- Encoding is canonical: fields in increasing field-number order, default
-- singular scalars and empty repeated fields omitted, present sub-messages
-- always emitted, repeated numeric fields always packed, minimal varints.
--
-- Each node is encoded exactly once: the encoder returns every message as a
-- byte count together with a 'Builder', so a parent learns its child's length
-- without re-encoding it, and the final bytes are produced in one pass.
module Protowire.Encode
  ( encodeMessage
  , encodeMessageBuilder
  , EncodeError (..)
  ) where

import Data.ByteString.Builder (Builder, int32LE, int64LE, toLazyByteString, word32LE, word64LE, byteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.ByteString (ByteString)
import Data.Bits (shiftL, (.|.))
import Data.Foldable (foldlM, toList)
import Data.Int (Int32)
import qualified Data.IntMap.Strict as IM
import qualified Data.Sequence as Seq
import Data.Word (Word32, Word64)
import Protowire.Schema
import Protowire.Value
import Protowire.Wire

-- | The tree does not fit the schema.
newtype EncodeError
  = -- | The named field holds a value of the wrong kind (or a list where a
    -- single value is expected, or vice versa).
    TypeMismatch ByteString
  deriving (Eq, Show)

-- | Encode a message to its canonical bytes.
--
-- Integer values are taken modulo the width of their schema type (an
-- @int32@ field holding 2^32 + 1 encodes as 1); range checking is the
-- business of the caller (the text parser does it).
encodeMessage :: MessageDesc -> Message -> Either EncodeError BL.ByteString
encodeMessage d m = toLazyByteString . snd <$> encodeMessageBuilder d m

-- | Encode a message to its length in bytes and a 'Builder' for them.
encodeMessageBuilder :: MessageDesc -> Message -> Either EncodeError (Int, Builder)
encodeMessageBuilder desc (Message fields) = foldlM step (0, mempty) (IM.toAscList fields)
  where
    step (!sz, !b) (num, slot) = case IM.lookup num (msgByNumber desc) of
      Nothing -> Right (sz, b) -- not part of the schema: ignored
      Just fd -> do
        (s, b') <- encodeSlot fd slot
        Right (sz + s, b <> b')

tag :: Int -> Int -> (Int, Builder)
tag num wt = let t = (fromIntegral num `shiftL` 3) .|. fromIntegral wt :: Word64 in (varintSize t, varint t)

lengthDelimited :: (Int, Builder) -> Int -> Builder -> (Int, Builder)
lengthDelimited (ts, tb) len body =
  let l = fromIntegral len :: Word64
   in (ts + varintSize l + len, tb <> varint l <> body)

encodeSlot :: FieldDesc -> Slot -> Either EncodeError (Int, Builder)
encodeSlot fd slot = case (slot, fieldRepeated fd) of
  (Single v, False)
    | isDefault v -> Right (0, mempty)
    | otherwise -> element v
  (Repeated vs, True)
    | Seq.null vs -> Right (0, mempty)
    | FScalar s <- ty, isPackable ty -> do
        parts <- traverse (maybe mismatch Right . numeric s) (toList vs)
        let len = sum (map fst parts)
        Right (lengthDelimited (tag num 2) len (foldMap snd parts))
    | otherwise -> do
        parts <- traverse element (toList vs)
        Right (sum (map fst parts), foldMap snd parts)
  _ -> mismatch
  where
    ty = fieldType fd
    num = fieldNumber fd
    mismatch :: Either EncodeError a
    mismatch = Left (TypeMismatch (fieldName fd))
    -- One element with its tag, unpacked form.
    element v = case (ty, v) of
      (FScalar TString, VString s) -> Right (bytesField s)
      (FScalar TBytes, VBytes s) -> Right (bytesField s)
      (FScalar s, _) | isPackable ty -> case numeric s v of
        Nothing -> mismatch
        Just (sz, b) ->
          let (ts, tb) = tag num (scalarWireType s) in Right (ts + sz, tb <> b)
      (FMessage sub, VMessage m) -> do
        (len, body) <- encodeMessageBuilder sub m
        Right (lengthDelimited (tag num 2) len body)
      _ -> mismatch
    bytesField s = lengthDelimited (tag num 2) (BS.length s) (byteString s)

-- | The payload (without tag) of a numeric scalar value.
numeric :: ScalarType -> Value -> Maybe (Int, Builder)
numeric t v = case (t, v) of
  (TInt32, VInt n) -> var (fromIntegral (fromIntegral n :: Int32))
  (TInt64, VInt n) -> var (fromIntegral n)
  (TUInt32, VWord n) -> var (fromIntegral (fromIntegral n :: Word32))
  (TUInt64, VWord n) -> var n
  (TSInt32, VInt n) -> var (fromIntegral (zigzag32 (fromIntegral n)))
  (TSInt64, VInt n) -> var (zigzag64 n)
  (TBool, VBool b) -> var (if b then 1 else 0)
  (TFixed32, VWord n) -> Just (4, word32LE (fromIntegral n))
  (TSFixed32, VInt n) -> Just (4, int32LE (fromIntegral n))
  (TFixed64, VWord n) -> Just (8, word64LE n)
  (TSFixed64, VInt n) -> Just (8, int64LE n)
  _ -> Nothing
  where
    var :: Word64 -> Maybe (Int, Builder)
    var w = Just (varintSize w, varint w)
