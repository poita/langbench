-- | Parsers for the small value grammars of SVG attributes: numbers,
-- lengths, colours, opacities, transform lists and @style@ declarations
-- (SPEC §4, §6, §7.2).
module Graphics.SVG.Raster.Parse
  ( -- * Numbers
    scanNumber
  , parseNumber
  , parseNumberList
  , parseLength
    -- * Paint
  , Paint (..)
  , parsePaint
  , parseOpacity
    -- * Transforms
  , parseTransform
    -- * Style
  , parseStyle
    -- * Helpers
  , skipSeparators
  , trim
  ) where

import Data.Char (isDigit, isHexDigit, digitToInt, isSpace, toLower)
import Data.List (isPrefixOf)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Ratio ((%))

import Graphics.SVG.Raster.Color
import Graphics.SVG.Raster.Geometry

-- | Remove leading and trailing whitespace.
trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

-- | Skip whitespace and commas.
skipSeparators :: String -> String
skipSeparators = dropWhile (\c -> isSpace c || c == ',')

-- | Scan a number (SPEC §4) from the start of the string, returning it and
-- the remaining input. An exponent not followed by a digit is not consumed.
scanNumber :: String -> Maybe (Double, String)
scanNumber s0 =
  let (sign, s1) = case s0 of
        '-' : r -> (-1, r)
        '+' : r -> (1, r)
        _ -> (1 :: Integer, s0)
      (intDigits, s2) = span isDigit s1
      (fracDigits, s3) = case s2 of
        '.' : r -> span isDigit r
        _ -> ("", s2)
      (expo, s4) = scanExponent s3
   in if null intDigits && null fracDigits
        then Nothing
        else
          let mant = digitsToInteger (intDigits ++ fracDigits)
              e = expo - length fracDigits
              e' = max (-400) (min 400 e)
              val
                | mant == 0 = 0
                | e' >= 0 = fromRational ((sign * mant * 10 ^ e') % 1)
                | otherwise = fromRational ((sign * mant) % (10 ^ negate e'))
           in Just (val, s4)
  where
    digitsToInteger = foldl (\a d -> a * 10 + fromIntegral (digitToInt d)) 0

scanExponent :: String -> (Int, String)
scanExponent (c : r)
  | c == 'e' || c == 'E' =
      let (sgn, r1) = case r of
            '-' : x -> (-1, x)
            '+' : x -> (1, x)
            _ -> (1, r)
          (ds, r2) = span isDigit r1
       in if null ds
            then (0, c : r)
            else (sgn * fromInteger (min 10000 (read ds)), r2)
scanExponent s = (0, s)

-- | Parse a whole string as a single number (surrounding whitespace allowed).
parseNumber :: String -> Maybe Double
parseNumber s = case scanNumber (dropWhile isSpace s) of
  Just (v, rest) | all isSpace rest -> Just v
  _ -> Nothing

-- | Parse a list of numbers separated by whitespace and/or commas. Parsing
-- stops at the first token that is not a number.
parseNumberList :: String -> [Double]
parseNumberList s = case scanNumber (skipSeparators s) of
  Just (v, rest) -> v : parseNumberList rest
  Nothing -> []

-- | Parse a length: a number optionally followed by @px@. Anything after the
-- number is ignored; 'Nothing' if the value does not start with a number.
parseLength :: String -> Maybe Double
parseLength s = fst <$> scanNumber (dropWhile isSpace s)

-- | A paint value.
data Paint
  = PaintNone
  | PaintCurrentColor
  | PaintColor !RGB
  deriving (Eq, Show)

-- | Parse a paint: @none@, @currentColor@, @#rgb@, @#rrggbb@, @rgb(...)@ or
-- a colour keyword.
parsePaint :: String -> Maybe Paint
parsePaint raw
  | v == "none" = Just PaintNone
  | v == "currentcolor" = Just PaintCurrentColor
  | '#' : hs <- t = PaintColor <$> hexColor hs
  | "rgb(" `isPrefixOf` v = PaintColor <$> rgbFunc (drop 4 t)
  | otherwise = PaintColor <$> namedColor t
  where
    t = trim raw
    v = map toLower t

hexColor :: String -> Maybe RGB
hexColor hs
  | not (all isHexDigit hs) = Nothing
  | [r, g, b] <- hs = Just (RGB (d r * 17) (d g * 17) (d b * 17))
  | [r1, r2, g1, g2, b1, b2] <- hs = Just (RGB (two r1 r2) (two g1 g2) (two b1 b2))
  | otherwise = Nothing
  where
    d = digitToInt
    two a b = 16 * d a + d b

rgbFunc :: String -> Maybe RGB
rgbFunc s = do
  (r, s1) <- component s
  (g, s2) <- component s1
  (b, s3) <- component s2
  case dropWhile isSpace s3 of
    ')' : _ -> Just (RGB r g b)
    _ -> Nothing
  where
    component str = do
      (v, rest) <- scanNumber (skipSeparators str)
      case rest of
        '%' : rest' -> Just (roundHalfAway (clampTo 100 v * 255 / 100), rest')
        _ -> Just (roundHalfAway (clampTo 255 v), rest)
    clampTo hi = max 0 . min hi
    roundHalfAway x = floor (x + 0.5 :: Double)

-- | Parse an opacity: a number or a percentage, clamped to @[0, 1]@.
parseOpacity :: String -> Maybe Double
parseOpacity s = case scanNumber (trim s) of
  Just (v, rest) -> case trim rest of
    "" -> Just (clamp01 v)
    "%" -> Just (clamp01 (v / 100))
    _ -> Nothing
  Nothing -> Nothing
  where
    clamp01 = max 0 . min 1

-- | Parse a @transform@ list into a single matrix. Unknown functions and
-- functions with too few arguments are skipped.
parseTransform :: String -> Affine
parseTransform = go identity
  where
    go acc s = case skipSeparators s of
      [] -> acc
      s1 ->
        let (name, s2) = span (\c -> c /= '(' && not (isSpace c) && c /= ',') s1
         in case dropWhile isSpace s2 of
              '(' : s3 ->
                let (argStr, s4) = break (== ')') s3
                    args = parseNumberList argStr
                 in go (maybe acc (compose acc) (transformFn name args)) (drop 1 s4)
              _ -> acc

transformFn :: String -> [Double] -> Maybe Affine
transformFn "matrix" (a : b : c : d : e : f : _) = Just (Affine a b c d e f)
transformFn "translate" [tx] = Just (translation tx 0)
transformFn "translate" (tx : ty : _) = Just (translation tx ty)
transformFn "scale" [sx] = Just (scaling sx sx)
transformFn "scale" (sx : sy : _) = Just (scaling sx sy)
transformFn "rotate" [a] = Just (rotationDeg a)
transformFn "rotate" (a : cx : cy : _) =
  Just (translation cx cy `compose` rotationDeg a `compose` translation (-cx) (-cy))
transformFn "skewX" (a : _) = Just (skewXDeg a)
transformFn "skewY" (a : _) = Just (skewYDeg a)
transformFn _ _ = Nothing

-- | Parse a @style@ attribute into a map from lower-cased property name to
-- trimmed value. Declarations without a colon and those with an empty value
-- are ignored; a later declaration of the same property replaces an earlier
-- one.
parseStyle :: String -> Map String String
parseStyle = foldl add Map.empty . splitOn ';'
  where
    add m decl = case break (== ':') decl of
      (n, ':' : v)
        | not (null (trim v)), not (null (trim n)) ->
            Map.insert (map toLower (trim n)) (trim v) m
      _ -> m

splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (a, _ : rest) -> a : splitOn c rest
  (a, []) -> [a]
