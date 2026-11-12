{-# LANGUAGE OverloadedStrings #-}

-- | The order-preserving index key encoding of SPEC §14.1.
module Tessera.IndexKey
  ( valueKey
  , entryKey
  , vkeyLength
  , documentKeyOf
  ) where

import Data.Bits (xor, setBit)
import qualified Data.ByteString as BS
import Data.ByteString.Builder (toLazyByteString, word64BE, word8)
import qualified Data.ByteString.Lazy as LBS
import Data.Word (Word64)
import Tessera.Value (Value (..))

-- | @vkey(value)@, or 'Nothing' for lists and objects, which are not indexed.
valueKey :: Value -> Maybe BS.ByteString
valueKey v = case v of
  VNull -> Just (BS.singleton 0x10)
  VBool False -> Just (BS.singleton 0x20)
  VBool True -> Just (BS.singleton 0x21)
  VInt i ->
    Just . LBS.toStrict . toLazyByteString $
      word8 0x30 <> word64BE ((fromIntegral i :: Word64) `xor` setBit 0 63)
  VString s ->
    Just (BS.concat [BS.singleton 0x40, BS.concatMap escape s, BS.pack [0, 0]])
  VList _ -> Nothing
  VObject _ -> Nothing
  where
    escape 0 = BS.pack [0, 0xFF]
    escape b = BS.singleton b

-- | The full index key @vkey(value) ++ document_key@.
entryKey :: Value -> BS.ByteString -> Maybe BS.ByteString
entryKey v docKey = (<> docKey) <$> valueKey v

-- | Length in bytes of the @vkey@ at the start of an index key.
vkeyLength :: BS.ByteString -> Int
vkeyLength k = case BS.uncons k of
  Just (0x30, _) -> 9
  Just (0x40, r) -> 1 + stringLen r 0
  _ -> 1
  where
    -- count bytes up to and including the "00 00" terminator
    stringLen r !n = case BS.uncons r of
      Just (0, r') -> case BS.uncons r' of
        Just (0xFF, r'') -> stringLen r'' (n + 2)
        _ -> n + 2
      Just (_, r') -> stringLen r' (n + 1)
      Nothing -> n

-- | The document key stored after the @vkey@.
documentKeyOf :: BS.ByteString -> BS.ByteString
documentKeyOf k = BS.drop (vkeyLength k) k
