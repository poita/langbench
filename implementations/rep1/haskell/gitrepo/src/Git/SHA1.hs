{-# LANGUAGE BangPatterns #-}

-- |
-- Module      : Git.SHA1
-- Description : SHA-1 (FIPS 180-4) over strict byte strings.
module Git.SHA1
  ( sha1
  , sha1Hex
  ) where

import Data.Bits (complement, rotateL, shiftL, shiftR, xor, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BU
import Data.Word (Word32, Word64, Word8)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peekElemOff, pokeElemOff)
import System.IO.Unsafe (unsafePerformIO)

data H = H !Word32 !Word32 !Word32 !Word32 !Word32

-- | The 20-byte SHA-1 digest of a message.
sha1 :: ByteString -> ByteString
sha1 msg = unsafePerformIO $ allocaBytes (80 * 4) $ \w -> do
  let n = BS.length msg
      fullBlocks = n `div` 64
      h0 = H 0x67452301 0xEFCDAB89 0x98BADCFE 0x10325476 0xC3D2E1F0
      goBlocks !i !h
        | i >= fullBlocks = pure h
        | otherwise = block w msg (i * 64) h >>= goBlocks (i + 1)
      rest = BS.drop (fullBlocks * 64) msg
      padLen = (55 - BS.length rest) `mod` 64
      bitLen = fromIntegral n * 8 :: Word64
      trailer =
        BS.concat
          [ rest
          , BS.singleton 0x80
          , BS.replicate padLen 0
          , BS.pack [fromIntegral (bitLen `shiftR` s) | s <- [56, 48 .. 0]]
          ]
      goTail !i !h
        | i >= BS.length trailer = pure h
        | otherwise = block w trailer i h >>= goTail (i + 64)
  H a b c d e <- goBlocks 0 h0 >>= goTail 0
  pure (BS.pack (concatMap be32 [a, b, c, d, e]))
  where
    be32 x = [fromIntegral (x `shiftR` s) | s <- [24, 16, 8, 0]]

-- | The digest as 40 lowercase hexadecimal digits.
sha1Hex :: ByteString -> ByteString
sha1Hex = BS.concatMap hex . sha1
  where
    hex x = BS.pack [d (x `shiftR` 4), d (x .&. 15)]
    d :: Word8 -> Word8
    d v = if v < 10 then 48 + v else 87 + v

-- | Process the 64-byte block at the given offset.
block :: Ptr Word32 -> ByteString -> Int -> H -> IO H
block w bs off (H h0 h1 h2 h3 h4) = do
  let byte i = fromIntegral (BU.unsafeIndex bs (off + i)) :: Word32
      load !t
        | t >= 16 = pure ()
        | otherwise = do
            let j = t * 4
            pokeElemOff w t $
              (byte j `shiftL` 24) .|. (byte (j + 1) `shiftL` 16)
                .|. (byte (j + 2) `shiftL` 8) .|. byte (j + 3)
            load (t + 1)
      expand !t
        | t >= 80 = pure ()
        | otherwise = do
            a <- peekElemOff w (t - 3)
            b <- peekElemOff w (t - 8)
            c <- peekElemOff w (t - 14)
            d <- peekElemOff w (t - 16)
            pokeElemOff w t ((a `xor` b `xor` c `xor` d) `rotateL` 1)
            expand (t + 1)
      rounds !t !a !b !c !d !e
        | t >= 80 = pure (H (h0 + a) (h1 + b) (h2 + c) (h3 + d) (h4 + e))
        | otherwise = do
            wt <- peekElemOff w t
            let (f, k)
                  | t < 20 = ((b .&. c) .|. (complement b .&. d), 0x5A827999)
                  | t < 40 = (b `xor` c `xor` d, 0x6ED9EBA1)
                  | t < 60 = ((b .&. c) .|. (b .&. d) .|. (c .&. d), 0x8F1BBCDC)
                  | otherwise = (b `xor` c `xor` d, 0xCA62C1D6 :: Word32)
                tmp = (a `rotateL` 5) + f + e + k + wt
            rounds (t + 1) tmp a (b `rotateL` 30) c d
  load 0
  expand 16
  rounds (0 :: Int) h0 h1 h2 h3 h4
