-- |
-- Module      : Data.BigInt.Decimal
-- Description : Linear-time decimal conversion for 'Magnitude'.
--
-- Because the limb base is a power of ten, each limb is exactly nine decimal
-- digits, so conversion in either direction is a single pass over the text.
module Data.BigInt.Decimal
  ( parseMagnitude
  , renderMagnitude
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.ByteString.Internal (unsafeCreate)
import Data.ByteString.Unsafe (unsafeIndex)
import Data.Word (Word8)
import Foreign.Ptr (Ptr, plusPtr)
import Foreign.Storable (pokeByteOff)

import Data.BigInt.Magnitude (Magnitude, fromLimbs, toLimbs)

-- | Parse a non-empty string of ASCII digits (leading zeros allowed).
-- Returns 'Nothing' for an empty string or any non-digit byte.
parseMagnitude :: BS.ByteString -> Maybe Magnitude
parseMagnitude s
  | BS.null s || not (BS.all isDigit s) = Nothing
  | otherwise = Just (fromLimbs [limb k | k <- [0 .. count - 1]])
  where
    digits = BS.dropWhile (== 48) s
    n = BS.length digits
    count = (n + 8) `quot` 9
    limb k =
      let hi = n - 9 * k
          lo = max 0 (hi - 9)
      in foldl' (\acc i -> acc * 10 + fromIntegral (unsafeIndex digits i - 48)) 0 [lo .. hi - 1]
    isDigit w = w >= 48 && w <= 57

-- | Canonical decimal rendering: no leading zeros, @"0"@ for zero.
renderMagnitude :: Magnitude -> BS.ByteString
renderMagnitude m = case reverse (toLimbs m) of
  [] -> BC.pack "0"
  top : rest ->
    let topDigits = length (show top)
        total = topDigits + 9 * length rest
    in unsafeCreate total $ \p -> do
         pokeLimb p topDigits top
         mapM_ (\(k, l) -> pokeLimb (p `plusPtr` (topDigits + 9 * k)) 9 l) (zip [0 ..] rest)

-- | Write @width@ decimal digits of the limb (zero padded) at the pointer.
pokeLimb :: Ptr Word8 -> Int -> Int -> IO ()
pokeLimb p width = go (width - 1)
  where
    go i x
      | i < 0 = return ()
      | otherwise = do
          let (q, r) = x `quotRem` 10
          pokeByteOff p i (fromIntegral r + 48 :: Word8)
          go (i - 1) q
