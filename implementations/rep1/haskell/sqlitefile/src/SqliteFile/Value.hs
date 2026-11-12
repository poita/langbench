-- | SQLite values, the ordering of Part 3 of the specification, and column
-- affinity.
module SqliteFile.Value
  ( Value (..)
  , compareValues
  , Affinity (..)
  , affinityOf
  , applyAffinity
  , scanNumeric
  , lowerAscii
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B
import Data.Char (isDigit)
import Data.Int (Int64)
import SqliteFile.Format (formatReal)

-- | A SQLite value. Text and blobs are raw bytes; text is UTF-8.
data Value
  = VNull
  | VInt !Int64
  | VReal !Double
  | VText !ByteString
  | VBlob !ByteString
  deriving (Eq, Show)

-- | Storage-class rank: NULL < numbers < TEXT < BLOB.
rank :: Value -> Int
rank VNull = 0
rank (VInt _) = 1
rank (VReal _) = 1
rank (VText _) = 2
rank (VBlob _) = 3

-- | Three-way comparison implementing the ordering of the spec. Integers are
-- compared exactly; an integer against a real is widened to a double; text
-- and blobs compare by unsigned bytes.
compareValues :: Value -> Value -> Ordering
compareValues (VInt a) (VInt b) = compare a b
compareValues (VInt a) (VReal b) = compare (fromIntegral a :: Double) b
compareValues (VReal a) (VInt b) = compare a (fromIntegral b :: Double)
compareValues (VReal a) (VReal b) = compare a b
compareValues (VText a) (VText b) = compare a b
compareValues (VBlob a) (VBlob b) = compare a b
compareValues a b = compare (rank a) (rank b)

-- | Column type affinity.
data Affinity = AffInteger | AffText | AffBlob | AffReal | AffNumeric
  deriving (Eq, Show)

-- | Derive the affinity from a declared type, applying the five rules in order.
affinityOf :: ByteString -> Affinity
affinityOf ty
  | has "INT" = AffInteger
  | has "CHAR" || has "CLOB" || has "TEXT" = AffText
  | has "BLOB" || BS.null ty = AffBlob
  | has "REAL" || has "FLOA" || has "DOUB" = AffReal
  | otherwise = AffNumeric
  where
    up = B.map toUpperAscii ty
    has p = B.pack p `BS.isInfixOf` up

toUpperAscii :: Char -> Char
toUpperAscii c
  | c >= 'a' && c <= 'z' = toEnum (fromEnum c - 32)
  | otherwise = c

-- | ASCII-only lower-casing (used for case-insensitive name matching).
lowerAscii :: ByteString -> ByteString
lowerAscii = B.map (\c -> if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c)

-- | Convert a query literal according to the affinity of the column it is
-- compared with. The first argument renders a real/integer as text.
applyAffinity :: Affinity -> Value -> Value
applyAffinity AffText v = case v of
  VInt i -> VText (B.pack (show i))
  VReal d -> VText (formatReal d)
  _ -> v
applyAffinity aff v@(VText t)
  | aff `elem` [AffInteger, AffReal, AffNumeric] =
      case scanNumeric True (trim t) of
        Just (n, rest) | BS.null rest -> n
        _ -> v
  | otherwise = v
applyAffinity _ v = v

trim :: ByteString -> ByteString
trim = B.dropWhileEnd isBlank . B.dropWhile isBlank
  where isBlank c = c == ' ' || c == '\t'

-- | Scan a numeric constant from the front of the input.
--
-- Grammar: @[+-]? (digits [. digits?] | . digits) ([eE][+-]?digits)?@. The
-- leading-dot form is only accepted when the first argument is 'True'. The
-- result is an integer when there is neither a point nor an exponent and the
-- value fits in 64 bits, a real otherwise. Returns the unconsumed rest.
scanNumeric :: Bool -> ByteString -> Maybe (Value, ByteString)
scanNumeric allowLeadingDot s0 = do
  let (neg, s1) = case B.uncons s0 of
        Just ('-', r) -> (True, r)
        Just ('+', r) -> (False, r)
        _ -> (False, s0)
      (intDs, s2) = B.span isDigit s1
  (fracDs, hasDot, s3) <-
    case B.uncons s2 of
      Just ('.', r)
        | not (B.null intDs) ->
            let (f, r') = B.span isDigit r in Just (f, True, r')
        | allowLeadingDot ->
            let (f, r') = B.span isDigit r
             in if B.null f then Nothing else Just (f, True, r')
        | otherwise -> Nothing
      _ | B.null intDs -> Nothing
        | otherwise -> Just (B.empty, False, s2)
  let (expo, s4) = scanExponent s3
      allDigits = B.append intDs fracDs
      mant = B.foldl' (\a c -> a * 10 + fromIntegral (fromEnum c - 48)) (0 :: Integer) allDigits
      signed = if neg then negate mant else mant
  if not hasDot && expo == Nothing
    then
      let v | signed >= toInteger (minBound :: Int64) && signed <= toInteger (maxBound :: Int64) = VInt (fromInteger signed)
            | otherwise = VReal (fromInteger signed)
       in Just (v, s4)
    else
      let e = maybe 0 id expo - toInteger (B.length fracDs)
          mag = toInteger (B.length (B.dropWhile (== '0') allDigits)) + e
          d | mant == 0 = if neg then -0.0 else 0.0
            | mag > 400 = if neg then 1 / 0 * (-1) else 1 / 0
            | mag < -400 = if neg then -0.0 else 0.0
            | otherwise = fromRational (fromInteger signed * 10 ^^ e)
       in Just (VReal d, s4)

-- | Optionally scan @[eE][+-]?digits@; if malformed, consume nothing.
scanExponent :: ByteString -> (Maybe Integer, ByteString)
scanExponent s = case B.uncons s of
  Just (c, r) | c == 'e' || c == 'E' ->
    let (sgn, r1) = case B.uncons r of
          Just ('-', x) -> (-1, x)
          Just ('+', x) -> (1, x)
          _ -> (1 :: Integer, r)
        (ds, r2) = B.span isDigit r1
     in if B.null ds
          then (Nothing, s)
          else
            let n = B.foldl' (\a ch -> min 1000000 (a * 10 + fromIntegral (fromEnum ch - 48))) (0 :: Integer) ds
             in (Just (sgn * n), r2)
  _ -> (Nothing, s)

