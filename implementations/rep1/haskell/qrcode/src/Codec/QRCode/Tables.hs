-- | Constant tables and capacity arithmetic from ISO/IEC 18004.
module Codec.QRCode.Tables
  ( minVersion
  , maxVersion
  , symbolSize
  , rawDataModules
  , totalCodewords
  , eccCodewordsPerBlock
  , numBlocks
  , dataCodewords
  , alignmentPositions
  ) where

import Data.Array (Array)
import qualified Data.Array as A
import Data.Array.Unboxed (UArray, listArray, (!))

import Codec.QRCode.Types (Ecl (..))

-- | Smallest version.
minVersion :: Int
minVersion = 1

-- | Largest version.
maxVersion :: Int
maxVersion = 40

-- | Side length in modules of a version's symbol.
symbolSize :: Int -> Int
symbolSize v = 4 * v + 17

-- | Number of modules that can hold data or error correction bits
-- (everything except function patterns), including remainder bits.
rawDataModules :: Int -> Int
rawDataModules v = r2 - (if v >= 7 then 36 else 0)
  where
    r0 = (16 * v + 128) * v + 64
    a = v `div` 7 + 2
    r2 = if v >= 2 then r0 - ((25 * a - 10) * a - 55) else r0

-- | Total codewords (data plus error correction) in a version.
totalCodewords :: Int -> Int
totalCodewords v = rawDataModules v `div` 8

eccIndex :: Ecl -> Int -> Int
eccIndex ecl v = fromEnum ecl * 40 + (v - 1)

-- | Error correction codewords in each block.
eccCodewordsPerBlock :: Ecl -> Int -> Int
eccCodewordsPerBlock ecl v = eccTable ! eccIndex ecl v

-- | Number of error correction blocks.
numBlocks :: Ecl -> Int -> Int
numBlocks ecl v = blockTable ! eccIndex ecl v

-- | Data codewords available at a version and level.
dataCodewords :: Ecl -> Int -> Int
dataCodewords ecl v =
  totalCodewords v - eccCodewordsPerBlock ecl v * numBlocks ecl v

-- | Alignment pattern centre coordinates for a version (empty for 1).
alignmentPositions :: Int -> [Int]
alignmentPositions 1 = []
alignmentPositions v = alignTable A.! v

eccTable :: UArray Int Int
eccTable = listArray (0, 159) $ concat
  [ -- L
    [ 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28
    , 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 ]
  , -- M
    [ 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26
    , 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28 ]
  , -- Q
    [ 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30
    , 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 ]
  , -- H
    [ 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28
    , 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 ]
  ]

blockTable :: UArray Int Int
blockTable = listArray (0, 159) $ concat
  [ -- L
    [ 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8
    , 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25 ]
  , -- M
    [ 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16
    , 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49 ]
  , -- Q
    [ 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20
    , 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68 ]
  , -- H
    [ 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25
    , 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81 ]
  ]

alignTable :: Array Int [Int]
alignTable = A.listArray (2, 40)
  [ [6, 18], [6, 22], [6, 26], [6, 30], [6, 34]
  , [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50], [6, 30, 54]
  , [6, 32, 58], [6, 34, 62], [6, 26, 46, 66], [6, 26, 48, 70]
  , [6, 26, 50, 74], [6, 30, 54, 78], [6, 30, 56, 82], [6, 30, 58, 86]
  , [6, 34, 62, 90], [6, 28, 50, 72, 94], [6, 26, 50, 74, 98]
  , [6, 30, 54, 78, 102], [6, 28, 54, 80, 106], [6, 32, 58, 84, 110]
  , [6, 30, 58, 86, 114], [6, 34, 62, 90, 118], [6, 26, 50, 74, 98, 122]
  , [6, 30, 54, 78, 102, 126], [6, 26, 52, 78, 104, 130]
  , [6, 30, 56, 82, 108, 134], [6, 34, 60, 86, 112, 138]
  , [6, 30, 58, 86, 114, 142], [6, 34, 62, 90, 118, 146]
  , [6, 30, 54, 78, 102, 126, 150], [6, 24, 50, 76, 102, 128, 154]
  , [6, 28, 54, 80, 106, 132, 158], [6, 32, 58, 84, 110, 136, 162]
  , [6, 26, 54, 82, 110, 138, 166], [6, 30, 58, 86, 114, 142, 170]
  ]
