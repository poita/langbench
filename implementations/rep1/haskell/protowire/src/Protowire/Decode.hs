{-# LANGUAGE BangPatterns #-}

-- |
-- Module      : Protowire.Decode
-- Description : Wire bytes to a 'Message' tree.
module Protowire.Decode
  ( decodeMessage
  , decodeInto
  , WireError (..)
  ) where

import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BU
import Data.Int (Int32)
import qualified Data.IntMap.Strict as IM
import qualified Data.Sequence as Seq
import Data.Word (Word32, Word64)
import Protowire.Schema
import Protowire.Utf8 (isValidUtf8)
import Protowire.Value
import Protowire.Wire

-- | Decode a complete message.  Unknown fields and fields with the wrong
-- wire type are skipped; later scalars replace earlier ones, repeated fields
-- append (packed or not) and repeated occurrences of a singular message
-- field are merged.
decodeMessage :: MessageDesc -> ByteString -> Either WireError Message
decodeMessage d = decodeInto d emptyMessage

-- | Like 'decodeMessage' but merging into an existing message, as when a
-- singular sub-message field occurs more than once.
decodeInto :: MessageDesc -> Message -> ByteString -> Either WireError Message
decodeInto desc start bs = go start 0
  where
    n = BS.length bs

    go :: Message -> Int -> Either WireError Message
    go !acc !i
      | i >= n = Right acc
      | otherwise = do
          (num, wt, i1) <- readTag bs i
          if wt == 4
            then Left UnmatchedEndGroup
            else case IM.lookup num (msgByNumber desc) of
              Nothing -> skipField num wt bs i1 >>= go acc
              Just fd -> field acc fd num wt i1

    field acc fd num wt i1
      | wt == wireTypeOf ty = case ty of
          FScalar s
            | wt == 2 -> do
                (l, i2) <- readLength bs i1
                let payload = slice i2 l
                v <- if s == TString then utf8 payload else Right (VBytes payload)
                store acc fd num v >>= \acc' -> go acc' (i2 + l)
            | otherwise -> do
                (v, i2) <- readScalar s bs i1
                acc' <- store acc fd num v
                go acc' (i2)
          FMessage sub -> do
            (l, i2) <- readLength bs i1
            let payload = slice i2 l
                existing = case IM.lookup num (messageFields acc) of
                  Just (Single (VMessage m)) | not (fieldRepeated fd) -> m
                  _ -> emptyMessage
            m <- decodeInto sub existing payload
            acc' <- store acc fd num (VMessage m)
            go acc' (i2 + l)
      | wt == 2 && fieldRepeated fd, FScalar s <- ty = do
          (l, i2) <- readLength bs i1
          vs <- readPacked s (slice i2 l)
          go (appendAll acc num vs) (i2 + l)
      | otherwise = skipField num wt bs i1 >>= go acc
      where
        ty = fieldType fd

    slice i l = BU.unsafeTake l (BU.unsafeDrop i bs)

    utf8 p
      | isValidUtf8 p = Right (VString p)
      | otherwise = Left InvalidUtf8

    store acc fd num v
      | fieldRepeated fd = Right (appendAll acc num (Seq.singleton v))
      | otherwise = Right (Message (IM.insert num (Single v) (messageFields acc)))

appendAll :: Message -> Int -> Seq.Seq Value -> Message
appendAll (Message m) num vs = Message (IM.alter f num m)
  where
    f (Just (Repeated old)) = Just (Repeated (old Seq.>< vs))
    f _ = Just (Repeated vs)

-- | Read one numeric element of a (non-string, non-bytes) scalar type.
readScalar :: ScalarType -> ByteString -> Int -> Either WireError (Value, Int)
readScalar s bs i = case scalarWireType s of
  0 -> do
    (w, i') <- readVarint 10 bs i
    Right (varintValue s w, i')
  1 -> if i + 8 <= BS.length bs then Right (fixed64Value s (le bs i 8), i + 8) else Left Truncated
  _ -> if i + 4 <= BS.length bs then Right (fixed32Value s (le bs i 4), i + 4) else Left Truncated

le :: ByteString -> Int -> Int -> Word64
le bs i k = go (k - 1) 0
  where
    go !j !acc
      | j < 0 = acc
      | otherwise = go (j - 1) ((acc `shiftL` 8) .|. fromIntegral (BU.unsafeIndex bs (i + j)))

varintValue :: ScalarType -> Word64 -> Value
varintValue s w = case s of
  TInt32 -> VInt (fromIntegral (fromIntegral w :: Int32))
  TInt64 -> VInt (fromIntegral w)
  TUInt32 -> VWord (fromIntegral (fromIntegral w :: Word32))
  TUInt64 -> VWord w
  TSInt32 -> VInt (fromIntegral (unzigzag32 (fromIntegral w)))
  TSInt64 -> VInt (unzigzag64 w)
  _ -> VBool (w /= 0)

fixed32Value :: ScalarType -> Word64 -> Value
fixed32Value TSFixed32 w = VInt (fromIntegral (fromIntegral w :: Int32))
fixed32Value _ w = VWord w

fixed64Value :: ScalarType -> Word64 -> Value
fixed64Value TSFixed64 w = VInt (fromIntegral w)
fixed64Value _ w = VWord w

-- | Decode the elements of a packed payload.
readPacked :: ScalarType -> ByteString -> Either WireError (Seq.Seq Value)
readPacked s payload = case scalarWireType s of
  0 -> go Seq.empty 0
  w | BS.length payload `mod` size /= 0 -> Left MalformedPacked
    | otherwise -> go Seq.empty 0
    where
      size = if w == 1 then 8 else 4
  where
    n = BS.length payload
    go !acc !i
      | i >= n = Right acc
      | otherwise = do
          (v, i') <- readScalar s payload i
          go (acc Seq.|> v) i'
