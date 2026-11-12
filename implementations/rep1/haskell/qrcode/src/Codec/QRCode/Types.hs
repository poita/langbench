-- | Core data types shared by every module of the encoder.
module Codec.QRCode.Types
  ( Ecl (..)
  , Mode (..)
  , MaskChoice (..)
  , QRError (..)
  , QRCode (..)
  , moduleAt
  , qrRows
  ) where

import Data.Array.Unboxed (UArray, (!))

-- | Error correction level, from least (@L@, ~7% recovery) to most
-- (@H@, ~30% recovery) redundancy.
data Ecl = L | M | Q | H
  deriving (Eq, Ord, Show, Read, Enum, Bounded)

-- | Segment encoding mode.
data Mode = Numeric | Alphanumeric | Byte
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | How to pick the mask pattern.
data MaskChoice
  = AutoMask
    -- ^ Score all eight masks with the standard penalty rules and take the
    -- best one (lowest number on ties).
  | FixedMask !Int
    -- ^ Use exactly this mask, which must be in @0..7@.
  deriving (Eq, Show)

-- | Reasons why encoding can fail.
data QRError
  = DataTooLong
    -- ^ The payload does not fit in any version (1..40) at the requested
    -- error correction level.
  | InvalidMask !Int
    -- ^ A 'FixedMask' outside @0..7@.
  deriving (Eq, Show)

-- | A finished symbol (without quiet zone).
data QRCode = QRCode
  { qrVersion :: !Int
    -- ^ Version, @1..40@.
  , qrMask    :: !Int
    -- ^ Mask pattern used, @0..7@.
  , qrEcl     :: !Ecl
    -- ^ Error correction level.
  , qrSize    :: !Int
    -- ^ Side length in modules, @4 * version + 17@.
  , qrModules :: !(UArray Int Bool)
    -- ^ Row-major module matrix (index @y * size + x@); 'True' is dark.
  }
  deriving (Eq, Show)

-- | @moduleAt qr x y@ is 'True' if the module in column @x@ and row @y@
-- (both 0-based from the top-left) is dark. Coordinates outside the symbol
-- are reported as light.
moduleAt :: QRCode -> Int -> Int -> Bool
moduleAt qr x y
  | x < 0 || y < 0 || x >= n || y >= n = False
  | otherwise = qrModules qr ! (y * n + x)
  where
    n = qrSize qr

-- | The symbol as rows of modules, top row first.
qrRows :: QRCode -> [[Bool]]
qrRows qr = [[moduleAt qr x y | x <- [0 .. n - 1]] | y <- [0 .. n - 1]]
  where
    n = qrSize qr
