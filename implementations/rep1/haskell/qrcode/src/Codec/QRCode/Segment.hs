-- | Mode selection, bit-length arithmetic and segment encoding.
--
-- A segment's bit stream is represented as a list of @(value, width)@
-- /fields/, written most-significant bit first; "Codec.QRCode.Codewords"
-- packs them into bytes.
module Codec.QRCode.Segment
  ( Field
  , selectMode
  , modeIndicator
  , charCountBits
  , dataBitLength
  , streamBitLength
  , chooseVersion
  , segmentFields
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.List (find)
import Data.Word (Word8)

import Codec.QRCode.Tables (dataCodewords, maxVersion, minVersion)
import Codec.QRCode.Types (Ecl, Mode (..))

-- | A @(value, bit width)@ pair.
type Field = (Int, Int)

alnumChars :: B.ByteString
alnumChars = BC.pack "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"

alnumValue :: Word8 -> Maybe Int
alnumValue = (`B.elemIndex` alnumChars)

-- | The first applicable mode: numeric, then alphanumeric, then byte.
selectMode :: B.ByteString -> Mode
selectMode s
  | B.all isDigit s = Numeric
  | B.all (\c -> B.elem c alnumChars) s = Alphanumeric
  | otherwise = Byte
  where
    isDigit c = c >= 0x30 && c <= 0x39

-- | The 4-bit mode indicator.
modeIndicator :: Mode -> Int
modeIndicator Numeric = 1
modeIndicator Alphanumeric = 2
modeIndicator Byte = 4

-- | Width of the character count field for a mode at a version.
charCountBits :: Mode -> Int -> Int
charCountBits mode v = case mode of
  Numeric -> pick 10 12 14
  Alphanumeric -> pick 9 11 13
  Byte -> pick 8 16 16
  where
    pick a b c
      | v <= 9 = a
      | v <= 26 = b
      | otherwise = c

-- | Bits of payload data for @n@ characters in a mode (closed form).
dataBitLength :: Mode -> Int -> Int
dataBitLength Numeric n = 10 * (n `div` 3) + [0, 4, 7] !! (n `mod` 3)
dataBitLength Alphanumeric n = 11 * (n `div` 2) + 6 * (n `mod` 2)
dataBitLength Byte n = 8 * n

-- | Mode indicator, count field and data for @n@ characters at a version.
streamBitLength :: Mode -> Int -> Int -> Int
streamBitLength mode v n = 4 + charCountBits mode v + dataBitLength mode n

-- | Smallest version whose capacity at the given level holds @n@ characters
-- of the given mode, if any.
chooseVersion :: Ecl -> Mode -> Int -> Maybe Int
chooseVersion ecl mode n = find fits [minVersion .. maxVersion]
  where
    fits v = streamBitLength mode v n <= 8 * dataCodewords ecl v

-- | The fields of a complete single segment (indicator, count, data) for the
-- given version. The mode must be applicable to the text (see 'selectMode').
segmentFields :: Mode -> Int -> B.ByteString -> [Field]
segmentFields mode v s =
  (modeIndicator mode, 4) : (B.length s, charCountBits mode v) : body
  where
    body = case mode of
      Numeric -> numeric (map digit (B.unpack s))
      Alphanumeric -> alnum (map (maybe 0 id . alnumValue) (B.unpack s))
      Byte -> [(fromIntegral b, 8) | b <- B.unpack s]
    digit c = fromIntegral c - 0x30 :: Int

    numeric (a : b : c : rest) = (100 * a + 10 * b + c, 10) : numeric rest
    numeric [a, b] = [(10 * a + b, 7)]
    numeric [a] = [(a, 4)]
    numeric [] = []

    alnum (a : b : rest) = (45 * a + b, 11) : alnum rest
    alnum [a] = [(a, 6)]
    alnum [] = []
