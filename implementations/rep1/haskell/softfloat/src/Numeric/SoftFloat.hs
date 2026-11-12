-- |
-- Module      : Numeric.SoftFloat
-- Description : IEEE-754 binary32 arithmetic on raw bit patterns
--
-- Addition, subtraction, multiplication, division and square root for
-- IEEE-754 single precision, computed with integer arithmetic only. All
-- operations round to nearest, ties to even, support denormals, and return
-- the canonical quiet NaN 'qNaN' (@0x7fc00000@) for NaN inputs and invalid
-- operations. Exception flags are not modelled.
--
-- Values are exchanged as 'Word32' bit patterns:
--
-- >>> import Numeric.SoftFloat
-- >>> f32Add 0x3f800000 0x3f800000   -- 1 + 1
-- 1073741824
module Numeric.SoftFloat
  ( F32
  , f32Add
  , f32Sub
  , f32Mul
  , f32Div
  , f32Sqrt
  , qNaN
  , isNaN32
  ) where

import Data.Word (Word32)

import Numeric.SoftFloat.Internal.Ops
import Numeric.SoftFloat.Internal.Unpack (Class (..), classify)

-- | A binary32 value as its raw bit pattern.
type F32 = Word32

-- | The canonical quiet NaN, @0x7fc00000@.
qNaN :: F32
qNaN = 0x7fc00000

-- | Is the pattern a NaN (any sign, payload, quiet or signaling)?
isNaN32 :: F32 -> Bool
isNaN32 w = classify w == CNaN
