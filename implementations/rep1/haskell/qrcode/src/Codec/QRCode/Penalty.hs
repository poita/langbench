-- | The mask penalty score (rules N1..N4) used for automatic mask choice.
module Codec.QRCode.Penalty
  ( penalty
  ) where

import Data.Array.Base (unsafeAt)
import Data.Array.Unboxed (UArray)
import Data.Bits (shiftL, (.&.), (.|.))


-- | Penalty score of a complete symbol of side @n@ (row-major modules).
--
-- * N1: runs of five or more equal modules in a row/column: @3 + (len - 5)@
-- * N2: every 2x2 block of one colour: 3
-- * N3: each occurrence of @#.###.#....@ or @....#.###.#@ in a row/column: 40
-- * N4: @10 * (|20 * dark - 10 * total| div total)@
penalty :: Int -> UArray Int Bool -> Int
penalty n g = linesScore + blocks + balance
  where
    dark :: Int -> Int
    dark i = if unsafeAt g i then 1 else 0

    linesScore =
      foldl'
        (\acc y -> acc + linePenalty n (\k -> dark (y * n + k)) + linePenalty n (\k -> dark (k * n + y)))
        0
        [0 .. n - 1]

    blocks =
      3 * length
        [ ()
        | y <- [0 .. n - 2], x <- [0 .. n - 2]
        , let i = y * n + x
              c = dark i
        , dark (i + 1) == c, dark (i + n) == c, dark (i + n + 1) == c
        ]

    total = n * n
    darkCount = foldl' (\a i -> a + dark i) 0 [0 .. total - 1]
    balance = 10 * (abs (20 * darkCount - 10 * total) `div` total)

-- | N1 and N3 for one line of @n@ modules given by an accessor (0 or 1).
linePenalty :: Int -> (Int -> Int) -> Int
linePenalty n get = go 0 (-1) 0 0 0
  where
    runScore r = if r >= 5 then r - 2 else 0
    go :: Int -> Int -> Int -> Int -> Int -> Int
    go !k !prev !run !w !acc
      | k == n = acc + runScore run
      | otherwise =
          let c = get k
              (run', acc1)
                | c == prev = (run + 1, acc)
                | otherwise = (1, acc + runScore run)
              w' = ((w `shiftL` 1) .|. c) .&. 0x7FF
              acc2 = if k >= 10 && (w' == 0x5D0 || w' == 0x05D) then acc1 + 40 else acc1
           in go (k + 1) c run' w' acc2
