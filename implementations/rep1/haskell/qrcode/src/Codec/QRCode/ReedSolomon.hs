-- | Arithmetic in GF(2^8) (primitive polynomial @x^8+x^4+x^3+x^2+1@) and
-- Reed-Solomon error correction codeword generation.
module Codec.QRCode.ReedSolomon
  ( gfMul
  , gfExp
  , generatorPoly
  , remainder
  ) where

import Control.Monad (forM_, when)
import Control.Monad.ST (ST)
import Data.Array.Base (unsafeAt, unsafeRead, unsafeWrite)
import Data.Array.ST (STUArray, newArray, runSTUArray)
import Data.Array.Unboxed (UArray, elems, listArray)
import Data.Bits (shiftL, xor)
import Data.Word (Word8)

expTable :: UArray Int Word8
expTable = listArray (0, 509) (map fromIntegral (take 510 (iterate step 1 :: [Int])))
  where
    step x = let y = x `shiftL` 1 in if y >= 256 then y `xor` 0x11D else y

logTable :: UArray Int Int
logTable = listArray (0, 255) (0 : [length (takeWhile (/= x) powers) | x <- [1 .. 255]])
  where
    powers = map fromIntegral (elems expTable) :: [Int]

-- | @gfExp i@ is @2^i@ in the field (@i@ taken modulo 255).
gfExp :: Int -> Word8
gfExp i = unsafeAt expTable (i `mod` 255)

-- | Field multiplication.
gfMul :: Word8 -> Word8 -> Word8
gfMul 0 _ = 0
gfMul _ 0 = 0
gfMul a b =
  unsafeAt expTable (unsafeAt logTable (fromIntegral a) + unsafeAt logTable (fromIntegral b))

-- | Coefficients of the degree-@e@ generator polynomial
-- @prod_{i<e} (x - 2^i)@, highest degree first, without the leading 1
-- (so exactly @e@ values).
generatorPoly :: Int -> [Word8]
generatorPoly e = drop 1 (foldl mulRoot [1] [0 .. e - 1])
  where
    mulRoot p i =
      let r = gfExp i
       in zipWith xor (p ++ [0]) (0 : map (gfMul r) p)

-- | @remainder e gen dat@ is the remainder of @dat(x) * x^e@ divided by the
-- generator polynomial @gen@ (as given by 'generatorPoly' @e@): the @e@
-- error correction codewords for @dat@, highest degree first.
remainder :: Int -> [Word8] -> [Word8] -> [Word8]
remainder e gen dat = elems $ runSTUArray $ do
  r <- newArray (0, max 0 (e - 1)) 0 :: ST s (STUArray s Int Word8)
  let g = listArray (0, e - 1) gen :: UArray Int Word8
  forM_ dat $ \d -> do
    top <- unsafeRead r 0
    let f = d `xor` top
    forM_ [0 .. e - 2] $ \i -> unsafeRead r (i + 1) >>= unsafeWrite r i
    unsafeWrite r (e - 1) 0
    when (f /= 0) $
      forM_ [0 .. e - 1] $ \i -> do
        x <- unsafeRead r i
        unsafeWrite r i (x `xor` gfMul f (unsafeAt g i))
  return r
