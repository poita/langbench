-- | Classification and unpacking of binary32 bit patterns.
module Numeric.SoftFloat.Internal.Unpack
  ( Class (..)
  , classify
  , signBit
  , isSignNeg
  , Finite (..)
  , unpackFinite
  , normalise
  ) where

import Data.Bits (countLeadingZeros, shiftL, shiftR, (.&.))
import Data.Word (Word32, Word64)

-- | Coarse classification of a binary32 pattern.
data Class = CNaN | CInf | CZero | CFinite
  deriving (Eq, Show)

classify :: Word32 -> Class
classify w
  | ex == 0xff = if frac /= 0 then CNaN else CInf
  | ex == 0 && frac == 0 = CZero
  | otherwise = CFinite
  where
    ex = (w `shiftR` 23) .&. 0xff
    frac = w .&. 0x7fffff

-- | The sign bit, in place (@0x80000000@ or @0@).
signBit :: Word32 -> Word32
signBit w = w .&. 0x80000000

isSignNeg :: Word32 -> Bool
isSignNeg w = w .&. 0x80000000 /= 0

-- | A finite nonzero magnitude @sig * 2^exp@ (sign is kept separately).
data Finite = Finite
  { finSig :: !Word64
  , finExp :: !Int
  } deriving (Eq, Show)

-- | Unpack a finite nonzero pattern. Denormals are /not/ normalised
-- (their significand has fewer than 24 bits).
unpackFinite :: Word32 -> Finite
unpackFinite w
  | ex == 0 = Finite frac (-149)
  | otherwise = Finite (frac + 0x800000) (ex - 150)
  where
    ex = fromIntegral ((w `shiftR` 23) .&. 0xff) :: Int
    frac = fromIntegral (w .&. 0x7fffff) :: Word64

-- | Shift the significand left until bit 23 is set, adjusting the exponent.
normalise :: Finite -> Finite
normalise (Finite s e) = Finite (s `shiftL` k) (e - k)
  where k = countLeadingZeros s - 40
