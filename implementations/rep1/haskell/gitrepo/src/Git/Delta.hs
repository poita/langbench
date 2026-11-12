{-# LANGUAGE BangPatterns #-}

-- |
-- Module      : Git.Delta
-- Description : Applying git delta streams to a base object.
module Git.Delta
  ( applyDelta
  ) where

import Data.Bits (shiftL, testBit, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Internal as BI
import qualified Data.ByteString.Unsafe as BU
import Foreign.ForeignPtr (withForeignPtr)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (Ptr, castPtr, plusPtr)
import System.IO.Unsafe (unsafeDupablePerformIO)

-- | @applyDelta base delta@ reconstructs an object from its base.
--
-- The delta starts with two little-endian base-128 sizes (base, result);
-- instructions follow: a /copy/ (high bit set) takes a range of the base,
-- an /insert/ takes literal bytes from the delta, and @0x00@ is invalid.
-- The result is 'Left' when a copy leaves the base, an instruction is
-- truncated, or the result length differs from the declared one.
applyDelta :: ByteString -> ByteString -> Either String ByteString
applyDelta base delta = do
  (_baseSize, p1) <- varint delta 0
  (resSize, p2) <- varint delta p1
  if resSize > 0x7fffffff then Left "delta: result too large" else pure ()
  unsafeDupablePerformIO $ do
    fp <- BI.mallocByteString resSize
    r <- withForeignPtr fp $ \dst -> run (castPtr dst) resSize p2
    pure $ case r of
      Nothing -> Right (BI.fromForeignPtr fp 0 resSize)
      Just err -> Left err
  where
    baseLen = BS.length base
    dlen = BS.length delta
    byteAt i = fromIntegral (BU.unsafeIndex delta i) :: Int

    run :: Ptr () -> Int -> Int -> IO (Maybe String)
    run dst resSize = go 0
      where
        go !op !ip
          | ip >= dlen = pure $
              if op == resSize then Nothing else Just "delta: result size mismatch"
          | otherwise =
              let c = byteAt ip
               in if c == 0
                    then pure (Just "delta: zero instruction")
                    else
                      if testBit c 7 then copyOp op ip c else insertOp op ip c

        insertOp op ip n
          | ip + 1 + n > dlen = pure (Just "delta: truncated insert")
          | op + n > resSize = pure (Just "delta: result overflows declared size")
          | otherwise = do
              BU.unsafeUseAsCString delta $ \src ->
                copyBytes (dst `plusPtr` op) (castPtr src `plusPtr` (ip + 1)) n
              go (op + n) (ip + 1 + n)

        copyOp op ip c =
          let offBytes = [i | i <- [0 .. 3], testBit c i]
              sizeBytes = [i | i <- [0 .. 2], testBit c (i + 4)]
              used = length offBytes + length sizeBytes
           in if ip + 1 + used > dlen
                then pure (Just "delta: truncated copy")
                else do
                  let fetch k = byteAt (ip + 1 + k)
                      offset = foldl (.|.) 0 [fetch k `shiftL` (8 * b) | (k, b) <- zip [0 ..] offBytes]
                      size0 = foldl (.|.) 0 [fetch (length offBytes + k) `shiftL` (8 * b) | (k, b) <- zip [0 ..] sizeBytes]
                      size = if size0 == 0 then 0x10000 else size0
                  if offset + size > baseLen
                    then pure (Just "delta: copy outside base")
                    else
                      if op + size > resSize
                        then pure (Just "delta: result overflows declared size")
                        else do
                          BU.unsafeUseAsCString base $ \src ->
                            copyBytes (dst `plusPtr` op) (castPtr src `plusPtr` offset) size
                          go (op + size) (ip + 1 + used)

    varint :: ByteString -> Int -> Either String (Int, Int)
    varint bs = loop 0 0
      where
        loop !acc !shiftBy !i
          | i >= BS.length bs = Left "delta: truncated header"
          | shiftBy > 56 = Left "delta: size too large"
          | otherwise =
              let b = fromIntegral (BU.unsafeIndex bs i) :: Int
                  acc' = acc .|. ((b .&. 0x7f) `shiftL` shiftBy)
               in if testBit b 7 then loop acc' (shiftBy + 7) (i + 1) else Right (acc', i + 1)
