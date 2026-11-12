{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Reading and writing the Matrix Market exchange format.
--
-- The reader accepts @coordinate@ and @array@ formats with the @real@,
-- @integer@ and @pattern@ fields and the @general@, @symmetric@ and
-- @skew-symmetric@ symmetries, and always produces a dense 'Matrix'. The
-- writer emits @array real general@ with every value formatted like C's
-- @printf("%.10e")@.
module Linalg.MatrixMarket
  ( parseMatrix
  , readMatrixFile
  , renderMatrix
  , writeMatrixFile
  , formatDouble
  , parseDouble
  ) where

import Control.Monad.ST (ST, runST)
import Data.Array.ST (newArray)
import Data.Bits (shiftL)
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8 as C
import Data.Char (isDigit, toLower)
import Data.Ratio ((%))
import System.IO (IOMode (WriteMode), withBinaryFile)

import Linalg.Internal (STU, wr)
import Linalg.Matrix (Matrix)
import qualified Linalg.Matrix as M

data Format = Coordinate | Array deriving (Eq)

data Field = Real | Pattern deriving (Eq)

data Symmetry = General | Symmetric | Skew deriving (Eq)

-- | Parse the contents of a Matrix Market file.
parseMatrix :: B.ByteString -> Either String Matrix
parseMatrix input = do
  let ls = map (C.dropWhileEnd isBlank . C.dropWhile isBlank) (C.lines input)
  (banner, rest) <- case ls of
    [] -> Left "empty file"
    (b : r) -> Right (b, r)
  (fmt, fld, sym) <- parseBanner banner
  let body = dropWhile (\l -> C.null l || C.head l == '%') rest
  (sizeLine, dataLines) <- case body of
    [] -> Left "missing size line"
    (s : d) -> Right (s, filter (not . C.null) d)
  sizes <- maybe (Left "bad size line") Right (mapM readInt (C.words sizeLine))
  case (fmt, sizes) of
    (Coordinate, [r, c, nnz]) -> coordinate fld sym r c nnz dataLines
    (Array, [r, c]) -> arrayFormat sym r c dataLines
    _ -> Left "size line does not match format"
  where
    isBlank ch = ch == ' ' || ch == '\t' || ch == '\r'

readInt :: C.ByteString -> Maybe Int
readInt t = case C.readInt t of
  Just (v, rest) | C.null rest -> Just v
  _ -> Nothing

parseBanner :: C.ByteString -> Either String (Format, Field, Symmetry)
parseBanner line = case map (map toLower . C.unpack) (C.words line) of
  ["%%matrixmarket", "matrix", f, fl, sy] -> do
    f' <- case f of
      "coordinate" -> Right Coordinate
      "array" -> Right Array
      _ -> Left ("unsupported format " ++ f)
    fl' <- case fl of
      "real" -> Right Real
      "integer" -> Right Real
      "pattern" -> Right Pattern
      _ -> Left ("unsupported field " ++ fl)
    sy' <- case sy of
      "general" -> Right General
      "symmetric" -> Right Symmetric
      "skew-symmetric" -> Right Skew
      _ -> Left ("unsupported symmetry " ++ sy)
    Right (f', fl', sy')
  _ -> Left "bad banner"

coordinate :: Field -> Symmetry -> Int -> Int -> Int -> [C.ByteString] -> Either String Matrix
coordinate fld sym r c nnz ls = do
  entries <- mapM entry (take nnz ls)
  if length entries /= nnz then Left "too few entries" else Right ()
  Right $ runST $ do
    arr <- newArray (0, max 0 (r * c - 1)) 0 :: ST s (STU s)
    mapM_ (store arr) entries
    M.unsafeFreezeMatrix r c arr
  where
    entry l = case (fld, C.words l) of
      (Pattern, [i, j]) -> orErr ((,,) <$> readInt i <*> readInt j <*> Just 1)
      (Real, [i, j, v]) -> orErr ((,,) <$> readInt i <*> readInt j <*> parseDouble v)
      _ -> Left "bad entry"
    orErr = maybe (Left "bad entry") Right
    store arr (i, j, v) = do
      wr arr ((i - 1) * c + (j - 1)) v
      if sym /= General && i /= j
        then wr arr ((j - 1) * c + (i - 1)) (if sym == Skew then negate v else v)
        else pure ()

arrayFormat :: Symmetry -> Int -> Int -> [C.ByteString] -> Either String Matrix
arrayFormat sym r c ls = do
  vals <- maybe (Left "bad value") Right (mapM (parseDouble . firstToken) ls)
  let positions = case sym of
        General -> [(i, j) | j <- [0 .. c - 1], i <- [0 .. r - 1]]
        Symmetric -> [(i, j) | j <- [0 .. c - 1], i <- [j .. r - 1]]
        Skew -> [(i, j) | j <- [0 .. c - 1], i <- [j + 1 .. r - 1]]
  if length vals < length positions then Left "too few values" else Right ()
  Right $ runST $ do
    arr <- newArray (0, max 0 (r * c - 1)) 0 :: ST s (STU s)
    mapM_
      ( \((i, j), v) -> do
          wr arr (i * c + j) v
          if sym /= General && i /= j
            then wr arr (j * c + i) (if sym == Skew then negate v else v)
            else pure ()
      )
      (zip positions vals)
    M.unsafeFreezeMatrix r c arr
  where
    firstToken l = case C.words l of
      (t : _) -> t
      [] -> ""

-- | Read and parse a Matrix Market file.
readMatrixFile :: FilePath -> IO (Either String Matrix)
readMatrixFile path = parseMatrix <$> B.readFile path

-- | Correctly rounded decimal-to-binary conversion of a token such as
-- @1@, @-2.5@, @3.0e-7@, @1.0E+03@, @.5@ or @5.@.
parseDouble :: C.ByteString -> Maybe Double
parseDouble tok0 = do
  let (neg, t1) = case C.uncons tok0 of
        Just ('-', r) -> (True, r)
        Just ('+', r) -> (False, r)
        _ -> (False, tok0)
      (intPart, t2) = C.span isDigit t1
      (fracPart, t3) = case C.uncons t2 of
        Just ('.', r) -> C.span isDigit r
        _ -> ("", t2)
  if C.null intPart && C.null fracPart then Nothing else Just ()
  ex <- case C.uncons t3 of
    Nothing -> Just 0
    Just (ch, r)
      | ch == 'e' || ch == 'E' -> case C.uncons r of
          Just ('-', d) -> negate <$> digitsInt d
          Just ('+', d) -> digitsInt d
          _ -> digitsInt r
    _ -> Nothing
  let sig = C.dropWhile (== '0') (C.append intPart fracPart)
      nsig = C.length sig
      e10 = ex - C.length fracPart
      mant = C.foldl' (\acc ch -> acc * 10 + toInteger (fromEnum ch - 48)) 0 sig :: Integer
      mag
        | nsig == 0 = 0
        | nsig <= 15 && e10 >= 0 && e10 <= 22 = fromInteger mant * 10 ^ e10
        | nsig <= 15 && e10 < 0 && e10 >= -22 = fromInteger mant / 10 ^ negate e10
        | nsig + e10 > 400 = 1 / 0
        | nsig + e10 < -400 = 0
        | e10 >= 0 = fromRational ((mant * 10 ^ e10) % 1)
        | otherwise = fromRational (mant % (10 ^ negate e10))
  Just (if neg then negate mag else mag)
  where
    digitsInt d
      | C.null d || not (C.all isDigit d) = Nothing
      | otherwise = Just (C.foldl' (\a ch -> a * 10 + (fromEnum ch - 48)) 0 (C.take 9 d))

-- | Render a matrix in @array real general@ form: banner, size line, then one
-- value per line in column-major order, with a trailing newline.
renderMatrix :: Matrix -> BB.Builder
renderMatrix m =
  "%%MatrixMarket matrix array real general\n"
    <> BB.intDec (M.rows m)
    <> BB.char7 ' '
    <> BB.intDec (M.cols m)
    <> BB.char7 '\n'
    <> mconcat [formatDouble (M.unsafeAt m i j) <> BB.char7 '\n' | j <- [0 .. M.cols m - 1], i <- [0 .. M.rows m - 1]]

-- | Write 'renderMatrix' output to a file.
writeMatrixFile :: FilePath -> Matrix -> IO ()
writeMatrixFile path m = withBinaryFile path WriteMode (\h -> BB.hPutBuilder h (renderMatrix m))

-- | Format like C's @printf("%.10e")@ (round-half-even on the exact binary
-- value), except that negative zero prints as positive zero.
formatDouble :: Double -> BB.Builder
formatDouble x
  | x == 0 = "0.0000000000e+00"
  | otherwise =
      (if x < 0 then BB.char7 '-' else mempty)
        <> BB.string7 (case show n10 of (d0 : ds) -> d0 : '.' : ds; [] -> "")
        <> BB.char7 'e'
        <> BB.char7 (if e10 < 0 then '-' else '+')
        <> BB.string7 (pad2 (show (abs e10)))
  where
    (n10, e10) = scaled (abs x)
    pad2 s = if length s < 2 then '0' : s else s

-- | For a positive finite double return @(N, e)@ with @10^10 <= N < 10^11@
-- and @N@ the correctly rounded value of @x / 10^(e-10)@.
scaled :: Double -> (Integer, Int)
scaled x = go (estimate x)
  where
    (mant, ex) = decodeFloat x
    go e10 =
      let d = e10 - 10
          num = mant * (if ex >= 0 then 1 `shiftL` ex else 1) * (if d < 0 then 10 ^ negate d else 1)
          den = (if ex < 0 then 1 `shiftL` negate ex else 1) * (if d >= 0 then 10 ^ d else 1)
          (q, r) = num `quotRem` den
          n = case compare (2 * r) den of
            GT -> q + 1
            EQ -> if odd q then q + 1 else q
            LT -> q
       in if n < 10 ^ (10 :: Int)
            then go (e10 - 1)
            else
              if n > 10 ^ (11 :: Int)
                then go (e10 + 1)
                else if n == 10 ^ (11 :: Int) then (10 ^ (10 :: Int), e10 + 1) else (n, e10)
    estimate v = floor (logBase 10 v :: Double) :: Int

