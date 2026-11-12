-- | The arithmetic kernels. Each one handles NaN, infinity and zero
-- operands directly and otherwise computes a truncated integer result plus a
-- sticky bit, which is handed to 'roundPack'. All intermediates fit in 64 bits.
module Numeric.SoftFloat.Internal.Ops
  ( f32Add
  , f32Sub
  , f32Mul
  , f32Div
  , f32Sqrt
  , isqrt
  ) where

import Data.Bits (shiftL, shiftR, xor, (.&.), (.|.))
import Data.Word (Word32, Word64)

import Numeric.SoftFloat.Internal.Round (roundPack)
import Numeric.SoftFloat.Internal.Unpack

qNaN, posInf :: Word32
qNaN = 0x7fc00000
posInf = 0x7f800000

-- | Result sign of a product or quotient, in place.
xorSign :: Word32 -> Word32 -> Word32
xorSign a b = signBit (a `xor` b)

f32Sub :: Word32 -> Word32 -> Word32
f32Sub a b = f32Add a (b `xor` 0x80000000)

f32Add :: Word32 -> Word32 -> Word32
f32Add a b = case (classify a, classify b) of
  (CNaN, _) -> qNaN
  (_, CNaN) -> qNaN
  (CInf, CInf) | a == b -> a
               | otherwise -> qNaN
  (CInf, _) -> a
  (_, CInf) -> b
  (CZero, CZero) | a == b -> a
                 | otherwise -> 0
  (CZero, _) -> b
  (_, CZero) -> a
  _ -> addFinite a b

-- | Sum of two finite nonzero operands.
addFinite :: Word32 -> Word32 -> Word32
addFinite a b
  | ma == mb && isSignNeg a /= isSignNeg b = 0
  | otherwise = go
  where
    ma = a .&. 0x7fffffff
    mb = b .&. 0x7fffffff
    -- (x, y): x has the larger magnitude
    (x, y) = if ma >= mb then (a, b) else (b, a)
    Finite sx ex = unpackFinite x
    Finite sy ey = unpackFinite y
    d = ex - ey
    big = sx `shiftL` 32
    small
      | d >= 64 = 0
      | otherwise = (sy `shiftL` 32) `shiftR` d
    lost
      | d >= 64 = True
      | otherwise = (sy `shiftL` 32) .&. ((1 `shiftL` d) - 1) /= 0
    sub = isSignNeg a /= isSignNeg b
    neg = isSignNeg x
    go
      | not sub = roundPack neg (big + small) (ex - 32) lost
      | lost = roundPack neg (big - small - 1) (ex - 32) True
      | otherwise = roundPack neg (big - small) (ex - 32) False

f32Mul :: Word32 -> Word32 -> Word32
f32Mul a b = case (classify a, classify b) of
  (CNaN, _) -> qNaN
  (_, CNaN) -> qNaN
  (CInf, CZero) -> qNaN
  (CZero, CInf) -> qNaN
  (CInf, _) -> posInf .|. s
  (_, CInf) -> posInf .|. s
  (CZero, _) -> s
  (_, CZero) -> s
  _ -> let Finite sa ea = unpackFinite a
           Finite sb eb = unpackFinite b
       in roundPack (isSignNeg s) (sa * sb) (ea + eb) False
  where s = xorSign a b

f32Div :: Word32 -> Word32 -> Word32
f32Div a b = case (classify a, classify b) of
  (CNaN, _) -> qNaN
  (_, CNaN) -> qNaN
  (CInf, CInf) -> qNaN
  (CZero, CZero) -> qNaN
  (CInf, _) -> posInf .|. s
  (_, CInf) -> s
  (CZero, _) -> s
  (_, CZero) -> posInf .|. s
  _ -> let Finite sa ea = normalise (unpackFinite a)
           Finite sb eb = normalise (unpackFinite b)
           num = sa `shiftL` 26
           (q, r) = num `quotRem` sb
       in roundPack (isSignNeg s) q (ea - eb - 26) (r /= 0)
  where s = xorSign a b

f32Sqrt :: Word32 -> Word32
f32Sqrt a = case classify a of
  CNaN -> qNaN
  CZero -> a
  CInf | isSignNeg a -> qNaN
       | otherwise -> a
  CFinite
    | isSignNeg a -> qNaN
    | otherwise ->
        let Finite s0 e0 = normalise (unpackFinite a)
            (s1, e1) = if odd e0 then (s0 `shiftL` 1, e0 - 1) else (s0, e0)
            (root, rm) = isqrt (s1 `shiftL` 28)
        in roundPack False root (e1 `div` 2 - 14) (rm /= 0)

-- | Restoring digit-by-digit integer square root of a value below 2^62:
-- returns @(r, n - r*r)@ with @r = floor (sqrt n)@.
isqrt :: Word64 -> (Word64, Word64)
isqrt n0 = go n0 0 start
  where
    start = top (1 `shiftL` 62)
    top bit | bit > n0 && bit /= 0 = top (bit `shiftR` 2)
            | otherwise = bit
    go n res bit
      | bit == 0 = (res, n)
      | n >= res + bit = go (n - res - bit) ((res `shiftR` 1) + bit) (bit `shiftR` 2)
      | otherwise = go n (res `shiftR` 1) (bit `shiftR` 2)
