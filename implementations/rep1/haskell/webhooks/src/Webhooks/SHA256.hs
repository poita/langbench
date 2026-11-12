{-# LANGUAGE BangPatterns #-}

-- | SHA-256 as specified by FIPS 180-4, implemented from scratch.
module Webhooks.SHA256
  ( sha256
  , digestLength
  , blockLength
  ) where

import Control.Monad.ST (ST, runST)
import Data.Array.Base (unsafeAt, unsafeRead, unsafeWrite)
import Data.Array.ST (STUArray, newArray)
import Data.Array.Unboxed (UArray, listArray)
import Data.Bits (complement, rotateR, shiftL, shiftR, xor, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BU
import Data.Word (Word32, Word64, Word8)

-- | Size of a SHA-256 digest in bytes (32).
digestLength :: Int
digestLength = 32

-- | Size of a SHA-256 message block in bytes (64).
blockLength :: Int
blockLength = 64

-- | The eight working variables / chaining state.
data State = State !Word32 !Word32 !Word32 !Word32 !Word32 !Word32 !Word32 !Word32

initialState :: State
initialState =
  State
    0x6a09e667 0xbb67ae85 0x3c6ef372 0xa54ff53a
    0x510e527f 0x9b05688c 0x1f83d9ab 0x5be0cd19

roundConstants :: UArray Int Word32
roundConstants =
  listArray
    (0, 63)
    [ 0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5
    , 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174
    , 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da
    , 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967
    , 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85
    , 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070
    , 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3
    , 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

-- | The SHA-256 digest (32 bytes) of a byte string of any length.
sha256 :: ByteString -> ByteString
sha256 msg = runST $ do
  w <- newArray (0, 63) 0
  let bodyLen = BS.length msg - BS.length msg `mod` blockLength
      tailBlocks = padTail msg bodyLen
      run bs !off !end !st
        | off >= end = pure st
        | otherwise = compress w bs off st >>= run bs (off + blockLength) end
  st1 <- run msg 0 bodyLen initialState
  st2 <- run tailBlocks 0 (BS.length tailBlocks) st1
  pure (serialise st2)

-- | The final one or two blocks: the leftover bytes, @0x80@, zeros, and the
-- 64-bit big-endian bit length of the whole message.
padTail :: ByteString -> Int -> ByteString
padTail msg bodyLen = BS.concat [rest, BS.singleton 0x80, BS.replicate zeros 0, lenBytes]
  where
    rest = BS.drop bodyLen msg
    zeros = (55 - BS.length rest) `mod` 64
    bitLen = fromIntegral (BS.length msg) * 8 :: Word64
    lenBytes = BS.pack [fromIntegral (bitLen `shiftR` s) | s <- [56, 48 .. 0]]

serialise :: State -> ByteString
serialise (State a b c d e f g h) = BS.pack (concatMap bytes [a, b, c, d, e, f, g, h])
  where
    bytes :: Word32 -> [Word8]
    bytes x = [fromIntegral (x `shiftR` s) | s <- [24, 16, 8, 0]]

-- | Process the 64-byte block of @bs@ starting at @off@.
compress :: forall s. STUArray s Int Word32 -> ByteString -> Int -> State -> ST s State
compress w bs off st0@(State h0 h1 h2 h3 h4 h5 h6 h7) = do
  loadWords 0
  expand 16
  State a b c d e f g h <- rounds 0 st0
  pure (State (h0 + a) (h1 + b) (h2 + c) (h3 + d) (h4 + e) (h5 + f) (h6 + g) (h7 + h))
  where
    byte :: Int -> Word32
    byte i = fromIntegral (BU.unsafeIndex bs i)

    loadWords :: Int -> ST s ()
    loadWords !t
      | t == 16 = pure ()
      | otherwise = do
          let i = off + 4 * t
              v = (byte i `shiftL` 24) .|. (byte (i + 1) `shiftL` 16)
                    .|. (byte (i + 2) `shiftL` 8) .|. byte (i + 3)
          unsafeWrite w t v
          loadWords (t + 1)

    expand :: Int -> ST s ()
    expand !t
      | t == 64 = pure ()
      | otherwise = do
          w15 <- unsafeRead w (t - 15)
          w2 <- unsafeRead w (t - 2)
          w16 <- unsafeRead w (t - 16)
          w7 <- unsafeRead w (t - 7)
          let s0 = rotateR w15 7 `xor` rotateR w15 18 `xor` (w15 `shiftR` 3)
              s1 = rotateR w2 17 `xor` rotateR w2 19 `xor` (w2 `shiftR` 10)
          unsafeWrite w t (w16 + s0 + w7 + s1)
          expand (t + 1)

    rounds :: Int -> State -> ST s State
    rounds !t !s@(State a b c d e f g h)
      | t == 64 = pure s
      | otherwise = do
          wt <- unsafeRead w t
          let s1 = rotateR e 6 `xor` rotateR e 11 `xor` rotateR e 25
              ch = (e .&. f) `xor` (complement e .&. g)
              temp1 = h + s1 + ch + unsafeAt roundConstants t + wt
              s0 = rotateR a 2 `xor` rotateR a 13 `xor` rotateR a 22
              maj = (a .&. b) `xor` (a .&. c) `xor` (b .&. c)
              temp2 = s0 + maj
          rounds (t + 1) (State (temp1 + temp2) a b c (d + temp1) e f g)
