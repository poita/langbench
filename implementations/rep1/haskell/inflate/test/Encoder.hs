-- | A tiny DEFLATE /encoder/ used only to generate test inputs: a bit writer,
-- stored blocks, and fixed-Huffman blocks built from explicit tokens.
module Encoder
  ( Token (..)
  , expand
  , storedBlock
  , fixedBlock
  , bitsToBytes
  , Bits
  , bitsLSB
  ) where

import Data.Bits (shiftR, testBit, (.&.))
import qualified Data.ByteString as B
import Data.Word (Word8)

-- | A bit sequence in stream order.
type Bits = [Bool]

-- | @bitsLSB n v@: the low @n@ bits of @v@, least significant first.
bitsLSB :: Int -> Int -> Bits
bitsLSB n v = [testBit v i | i <- [0 .. n - 1]]

-- | @bitsMSB n v@: the low @n@ bits of @v@, most significant first (Huffman codes).
bitsMSB :: Int -> Int -> Bits
bitsMSB n v = [testBit v i | i <- [n - 1, n - 2 .. 0]]

-- | Pack bits into bytes, padding the last byte with zeros.
bitsToBytes :: Bits -> B.ByteString
bitsToBytes [] = B.empty
bitsToBytes bs = B.pack (go bs)
  where
    go [] = []
    go xs = let (h, t) = splitAt 8 xs in byte h : go t
    byte :: Bits -> Word8
    byte h = foldl' (\a (i, b) -> if b then a + 2 ^ (i :: Int) else a) 0 (zip [0 ..] h)

data Token
  = Lit Word8
  | Match Int Int  -- ^ length (3..258), distance (1..32768)
  deriving (Show, Eq)

-- | The bytes a token list decodes to (copies may overlap).
expand :: [Token] -> B.ByteString
expand = B.pack . reverse . foldl' step []
  where
    step acc (Lit b) = b : acc
    step acc (Match l d) = go l acc
      where
        go 0 a = a
        go k a = go (k - 1 :: Int) ((a !! (d - 1)) : a)

-- | A single stored block (@LEN@ must be below 65536). The header is padded to
-- a byte boundary, so this is only correct as the first block.
storedBlock :: Bool -> B.ByteString -> B.ByteString
storedBlock final payload =
  B.concat
    [ B.pack [if final then 1 else 0]
    , B.pack [lo n, hi n, lo (n' ), hi n']
    , payload
    ]
  where
    n = B.length payload
    n' = 0xFFFF - n
    lo x = fromIntegral (x .&. 255)
    hi x = fromIntegral (x `shiftR` 8)

fixedLit :: Int -> Bits
fixedLit s
  | s < 144 = bitsMSB 8 (0x30 + s)
  | s < 256 = bitsMSB 9 (0x190 + s - 144)
  | s < 280 = bitsMSB 7 (s - 256)
  | otherwise = bitsMSB 8 (0xC0 + s - 280)

lenTable :: [(Int, Int, Int)]  -- (symbol, extra bits, base)
lenTable = zip3 [257 ..] extra base
  where
    extra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    base = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]

distTable :: [(Int, Int, Int)]
distTable = zip3 [0 ..] extra base
  where
    extra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    base = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]

pick :: [(Int, Int, Int)] -> Int -> (Int, Int, Int)
pick tbl v = last [e | e@(_, _, b) <- tbl, b <= v]

-- | Encode tokens as bits of a fixed-Huffman block (header included).
fixedBlock :: Bool -> [Token] -> Bits
fixedBlock final toks =
  [final] ++ bitsLSB 2 1 ++ concatMap tok toks ++ fixedLit 256
  where
    tok (Lit b) = fixedLit (fromIntegral b)
    tok (Match l d) =
      let (ls, le, lb) = pick lenTable l
          (ds, de, db) = pick distTable d
      in fixedLit ls ++ bitsLSB le (l - lb) ++ bitsMSB 5 ds ++ bitsLSB de (d - db)
