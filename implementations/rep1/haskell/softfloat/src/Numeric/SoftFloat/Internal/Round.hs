-- | The single shared round-and-pack step.
module Numeric.SoftFloat.Internal.Round
  ( roundPack
  ) where

import Data.Bits (countLeadingZeros, shiftL, shiftR, (.&.))
import Data.Word (Word32, Word64)

-- | @roundPack neg sig e sticky@ rounds the positive value
-- @(sig + eps) * 2^e@ to binary32 (nearest, ties to even), where
-- @0 <= eps < 1@ and @eps > 0@ exactly when @sticky@ is set.
--
-- @sig@ must be nonzero and below @2^63@. Rounding goes directly onto the
-- normal or denormal grid, so there is no double rounding. Overflow gives
-- infinity. The returned pattern includes the sign.
roundPack :: Bool -> Word64 -> Int -> Bool -> Word32
roundPack neg sig0 e0 sticky = sgn (finish bits)
  where
    -- Put the leading bit at position 62: value = sig * 2^e, exponent of
    -- the leading bit is e + 62.
    lz = countLeadingZeros sig0 - 1
    sig = sig0 `shiftL` lz
    e = e0 - lz
    lead = e + 62
    -- Number of low bits to drop: keep 24 bits for normals, or stop at the
    -- 2^-149 grid for denormals. Always >= 39 because sig has 63 bits.
    sh = max 39 (-149 - e)
    (q, up)
      | sh >= 64 = (0, False)
      | otherwise =
          let q0 = sig `shiftR` sh
              rm = sig .&. ((1 `shiftL` sh) - 1)
              half = 1 `shiftL` (sh - 1)
              u = rm > half || (rm == half && (sticky || q0 .&. 1 == 1))
          in (q0, u)
    q' = q + (if up then 1 else 0)
    base = max 0 (lead + 126)
    -- For normals q has the implicit bit (bit 23) set, which carries into
    -- the exponent field; for denormals base is 0 and q is the raw fraction
    -- (rounding up to 2^23 yields the smallest normal).
    bits = (fromIntegral base `shiftL` 23) + fromIntegral q' :: Word64
    finish b
      | b >= 0x7f800000 = 0x7f800000
      | otherwise = fromIntegral b
    sgn w = if neg then w + 0x80000000 else w
