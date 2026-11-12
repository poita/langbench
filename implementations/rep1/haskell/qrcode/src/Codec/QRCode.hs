-- | A from-scratch QR Code Model 2 (ISO/IEC 18004) encoder.
--
-- >>> import qualified Data.ByteString.Char8 as BC
-- >>> let Right qr = encode M AutoMask (BC.pack "HELLO WORLD")
-- >>> (qrVersion qr, qrMask qr, qrSize qr)
-- (1,0,21)
--
-- The payload is encoded as a single segment (numeric, alphanumeric or byte
-- mode, whichever is the first that applies), in the smallest version that
-- holds it. No ECI header is emitted; text is encoded as its UTF-8 bytes.
module Codec.QRCode
  ( -- * Encoding
    encode
  , encodeText
    -- * Types
  , Ecl (..)
  , Mode (..)
  , MaskChoice (..)
  , QRError (..)
  , QRCode (..)
  , moduleAt
  , qrRows
    -- * Rendering
  , renderRows
  , renderSymbol
    -- * Inspection
  , penaltyScore
  , capacityBytes
  ) where

import qualified Data.ByteString as B
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Codec.QRCode.Codewords (buildCodewords, padDataCodewords)
import Codec.QRCode.Matrix
import Codec.QRCode.Penalty (penalty)
import Codec.QRCode.Render (renderRows, renderSymbol)
import Codec.QRCode.Segment
import Codec.QRCode.Tables (dataCodewords, maxVersion, symbolSize)
import Codec.QRCode.Types

-- | Encode a byte string. The mode (numeric, alphanumeric, byte) and the
-- version are chosen automatically.
--
-- Each call does the work for the symbol once: the function patterns and
-- data are placed a single time, and with 'AutoMask' all eight masks are
-- then scored in full.
encode :: Ecl -> MaskChoice -> B.ByteString -> Either QRError QRCode
encode ecl choice payload
  | FixedMask m <- choice, m < 0 || m > 7 = Left (InvalidMask m)
  | otherwise = case chooseVersion ecl mode (B.length payload) of
      Nothing -> Left DataTooLong
      Just v -> Right (build v)
  where
    mode = selectMode payload

    build v =
      let n = symbolSize v
          fields = segmentFields mode v payload
          codewords = buildCodewords ecl v (padDataCodewords ecl v fields)
          tpl = buildTemplate v
          unmasked = placeData v tpl codewords
          withMask k = applyMask v tpl ecl k unmasked
          (m, grid) = case choice of
            FixedMask k -> (k, withMask k)
            AutoMask ->
              let scored = [(penalty n g, k, g) | k <- [0 .. 7], let g = withMask k]
                  (_, bestK, bestG) = foldr1 pick scored
                  pick a@(sa, _, _) b@(sb, _, _) = if sa <= sb then a else b
               in (bestK, bestG)
       in QRCode {qrVersion = v, qrMask = m, qrEcl = ecl, qrSize = n, qrModules = grid}

-- | Encode text as its UTF-8 bytes.
encodeText :: Ecl -> MaskChoice -> T.Text -> Either QRError QRCode
encodeText ecl choice = encode ecl choice . TE.encodeUtf8

-- | The mask penalty score (rules N1..N4) of a finished symbol.
penaltyScore :: QRCode -> Int
penaltyScore qr = penalty (qrSize qr) (qrModules qr)

-- | Largest payload in bytes (byte mode) a level can hold, i.e. at version 40.
capacityBytes :: Ecl -> Int
capacityBytes ecl = (8 * dataCodewords ecl maxVersion - 4 - 16) `div` 8
