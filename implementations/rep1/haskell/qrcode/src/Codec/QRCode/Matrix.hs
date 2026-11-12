-- | Module-matrix construction: function patterns, zigzag data placement,
-- masking and format information.
--
-- Matrices are flat, row-major arrays indexed by @y * n + x@.
module Codec.QRCode.Matrix
  ( Template (..)
  , buildTemplate
  , placeData
  , applyMask
  , formatBits
  , versionBits
  ) where

import Control.Monad (forM_, when)
import Control.Monad.ST (ST, runST)
import Data.Array.Base (unsafeAt, unsafeFreeze, unsafeRead, unsafeWrite)
import Data.Array.ST (STUArray, newArray, runSTUArray, thaw)
import Data.Array.Unboxed (UArray)
import Data.Bits (shiftL, shiftR, testBit, xor, (.&.), (.|.))
import Data.Word (Word8)

import Codec.QRCode.Tables (alignmentPositions, symbolSize)
import Codec.QRCode.Types (Ecl (..))

-- | The symbol skeleton before data is placed.
data Template = Template
  { tplDark :: !(UArray Int Bool)
    -- ^ Dark function modules (everything else 'False').
  , tplFunc :: !(UArray Int Bool)
    -- ^ Which modules are function modules (never masked, never data).
    -- The format information area is flagged here but left light.
  }

-- | 15-bit format information (with BCH code, XOR-masked with @0x5412@).
formatBits :: Ecl -> Int -> Int
formatBits ecl mask = ((d `shiftL` 10) .|. rm) `xor` 0x5412
  where
    eclBits = case ecl of L -> 1; M -> 0; Q -> 3; H -> 2
    d = (eclBits `shiftL` 3) .|. mask
    rm = iterate (\r -> (r `shiftL` 1) `xor` ((r `shiftR` 9) * 0x537)) d !! 10

-- | 18-bit version information (versions 7 and up).
versionBits :: Int -> Int
versionBits v = (v `shiftL` 12) .|. rm
  where
    rm = iterate (\r -> (r `shiftL` 1) `xor` ((r `shiftR` 11) * 0x1F25)) v !! 12

-- | Positions @(bit index, x, y)@ of both copies of the format information.
formatModules :: Int -> [(Int, Int, Int)]
formatModules n =
  [(i, 8, i) | i <- [0 .. 5]]
    ++ [(6, 8, 7), (7, 8, 8), (8, 7, 8)]
    ++ [(i, 14 - i, 8) | i <- [9 .. 14]]
    ++ [(i, n - 1 - i, 8) | i <- [0 .. 7]]
    ++ [(i, 8, n - 15 + i) | i <- [8 .. 14]]

-- | Draw all function patterns of a version.
buildTemplate :: Int -> Template
buildTemplate v = runST $ do
  dark <- newArray (0, n * n - 1) False :: ST s (STUArray s Int Bool)
  func <- newArray (0, n * n - 1) False :: ST s (STUArray s Int Bool)
  let set x y d = when (x >= 0 && y >= 0 && x < n && y < n) $ do
        unsafeWrite func (y * n + x) True
        unsafeWrite dark (y * n + x) d
      cheb dx dy = max (abs dx) (abs dy)
  -- Finder patterns with separators.
  forM_ [(3, 3), (n - 4, 3), (3, n - 4)] $ \(cx, cy) ->
    forM_ [-4 .. 4] $ \dy -> forM_ [-4 .. 4] $ \dx ->
      set (cx + dx) (cy + dy) (cheb dx dy `elem` [0, 1, 3])
  -- Timing patterns.
  forM_ [8 .. n - 9] $ \i -> do
    set i 6 (even i)
    set 6 i (even i)
  -- Alignment patterns.
  let ps = alignmentPositions v
      (firstP, lastP) = if null ps then (0, 0) else (minimum ps, maximum ps)
      centres =
        [ (px, py)
        | px <- ps, py <- ps
        , not ((px, py) `elem` [(firstP, firstP), (lastP, firstP), (firstP, lastP)])
        ]
  forM_ centres $ \(cx, cy) ->
    forM_ [-2 .. 2] $ \dy -> forM_ [-2 .. 2] $ \dx ->
      set (cx + dx) (cy + dy) (cheb dx dy /= 1)
  -- Dark module, reserved format area, version information.
  set 8 (n - 8) True
  forM_ (formatModules n) $ \(_, x, y) -> unsafeWrite func (y * n + x) True
  when (v >= 7) $ do
    let vb = versionBits v
    forM_ [0 .. 17] $ \i -> do
      let d = testBit vb i
          a = n - 11 + i `mod` 3
          b = i `div` 3
      set a b d
      set b a d
  Template <$> freezeBool dark <*> freezeBool func
  where
    n = symbolSize v

freezeBool :: STUArray s Int Bool -> ST s (UArray Int Bool)
freezeBool = unsafeFreeze

-- | Place the final codeword sequence along the zigzag in the non-function
-- modules. Modules left over (remainder bits) stay light. The result is the
-- unmasked symbol, with function patterns and the (still light) format area.
placeData :: Int -> Template -> [Word8] -> UArray Int Bool
placeData v (Template dark func) codewords = runSTUArray $ do
  grid <- thaw dark
  let bits = concatMap (\w -> [testBit w k | k <- [7, 6 .. 0]]) codewords
      slots =
        [ y * n + x
        | right <- rights
        , let upward = ((right + 1) .&. 2) == 0
        , y <- if upward then [n - 1, n - 2 .. 0] else [0 .. n - 1]
        , x <- [right, right - 1]
        , not (unsafeAt func (y * n + x))
        ]
  forM_ (zip slots bits) $ \(i, b) -> when b (unsafeWrite grid i True)
  return grid
  where
    n = symbolSize v
    -- Column 6 is skipped: after 8 the pairs continue at 5, 3, 1.
    rights = [n - 1, n - 3 .. 8] ++ [5, 3, 1]

-- | Is the module at @(x, y)@ inverted by the given mask pattern?
maskCondition :: Int -> Int -> Int -> Bool
maskCondition m x y = case m of
  0 -> (x + y) `mod` 2 == 0
  1 -> y `mod` 2 == 0
  2 -> x `mod` 3 == 0
  3 -> (x + y) `mod` 3 == 0
  4 -> (x `div` 3 + y `div` 2) `mod` 2 == 0
  5 -> (x * y) `mod` 2 + (x * y) `mod` 3 == 0
  6 -> ((x * y) `mod` 2 + (x * y) `mod` 3) `mod` 2 == 0
  _ -> ((x + y) `mod` 2 + (x * y) `mod` 3) `mod` 2 == 0

-- | Apply mask @m@ to an unmasked symbol and write the format information
-- for @ecl@ and @m@, giving the finished symbol.
applyMask :: Int -> Template -> Ecl -> Int -> UArray Int Bool -> UArray Int Bool
applyMask v (Template _ func) ecl m unmasked = runSTUArray $ do
  grid <- thaw unmasked
  forM_ [0 .. n - 1] $ \y -> forM_ [0 .. n - 1] $ \x -> do
    let i = y * n + x
    when (not (unsafeAt func i) && maskCondition m x y) $ do
      b <- unsafeRead grid i
      unsafeWrite grid i (not b)
  let fb = formatBits ecl m
  forM_ (formatModules n) $ \(k, x, y) -> unsafeWrite grid (y * n + x) (testBit fb k)
  return grid
  where
    n = symbolSize v
