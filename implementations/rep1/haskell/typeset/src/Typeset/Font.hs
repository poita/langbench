-- | Font metric files (@.cfm@) and face resolution.
module Typeset.Font
  ( Face (..)
  , Fonts
  , parseFace
  , loadFonts
  , fontsFromFaces
  , resolveFace
  , faceNameFor
  , advance
  , kernPair
  , textUnits
  , textWidth
  , charWidth
  , ioReadUtf8
  , stripComment
  , trim
  ) where

import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict as M
import Data.Char (ord)
import System.FilePath ((</>), (<.>))
import System.IO

import Typeset.Types
import Typeset.Units (scale)

-- | The metrics of one face.  All numbers are in thousandths of an em.
data Face = Face
  { faceName    :: String
  , faceFamily  :: Family
  , faceAscent  :: !Int
  , faceDescent :: !Int
  , faceSpace   :: !Int
  , faceStretch :: !Int
  , faceShrink  :: !Int
  , faceExtra   :: !Int
  , faceDefault :: !Int
  , faceGlyphs  :: IM.IntMap Int
  , faceKerns   :: IM.IntMap Int  -- ^ keyed by @cp1 * 2^21 + cp2@
  }

instance Eq Face where
  a == b = faceName a == faceName b

instance Show Face where
  show = faceName

-- | The nine faces, by name.
newtype Fonts = Fonts (M.Map String Face)

-- | Build a font set from parsed faces.
fontsFromFaces :: [Face] -> Fonts
fontsFromFaces fs = Fonts (M.fromList [(faceName f, f) | f <- fs])

-- | The face name for a (family, bold, italic) style.
faceNameFor :: Family -> Bool -> Bool -> String
faceNameFor Mono _ _ = "mono"
faceNameFor fam b i = base ++ (if b then "-bold" else "") ++ (if i then "-italic" else "")
  where base = if fam == Serif then "serif" else "sans"

-- | Resolve a style to its face.  Fails loudly if the font set is incomplete.
resolveFace :: Fonts -> Family -> Bool -> Bool -> Face
resolveFace (Fonts m) fam b i =
  case M.lookup n m of
    Just f -> f
    Nothing -> error ("missing font face: " ++ n)
  where n = faceNameFor fam b i

-- | Remove a @#@ comment and surrounding blanks.
stripComment :: String -> String
stripComment = trim . takeWhile (/= '#')

-- | Trim spaces and tabs from both ends.
trim :: String -> String
trim = f . f where f = reverse . dropWhile (`elem` " \t")

-- | Parse the text of a @.cfm@ file.
parseFace :: String -> Face
parseFace txt = foldl step blank (filter (not . null) (map (words . stripComment) (lines txt)))
  where
    blank = Face "" Serif 0 0 0 0 0 0 0 IM.empty IM.empty
    step f ws = case ws of
      ["face", n] -> f { faceName = n, faceFamily = fam n }
      ["ascent", a] -> f { faceAscent = num a }
      ["descent", a] -> f { faceDescent = num a }
      ["space", a, s, h] -> f { faceSpace = num a, faceStretch = num s, faceShrink = num h }
      ["extra", a] -> f { faceExtra = num a }
      ["default", a] -> f { faceDefault = num a }
      ["glyph", c, a] -> f { faceGlyphs = IM.insert (num c) (num a) (faceGlyphs f) }
      ["kern", a, b, u] -> f { faceKerns = IM.insert (kernKey (num a) (num b)) (num u) (faceKerns f) }
      _ -> f
    num :: String -> Int
    num = read . dropPlus
    dropPlus ('+' : r) = r
    dropPlus r = r
    fam n | take 4 n == "mono" = Mono
          | take 4 n == "sans" = Sans
          | otherwise = Serif

kernKey :: Int -> Int -> Int
kernKey a b = a * 2097152 + b

-- | Read a UTF-8 file regardless of the process locale.
ioReadUtf8 :: FilePath -> IO String
ioReadUtf8 p = do
  h <- openFile p ReadMode
  hSetEncoding h utf8
  s <- hGetContents h
  length s `seq` hClose h
  return s

-- | Load the nine faces from @\<dataDir\>/faces@.
loadFonts :: FilePath -> IO Fonts
loadFonts dataDir = do
  fs <- mapM (\n -> parseFace <$> ioReadUtf8 (dataDir </> "faces" </> n <.> "cfm")) names
  return (fontsFromFaces fs)
  where
    names = [ f ++ v | f <- ["serif", "sans"], v <- ["", "-bold", "-italic", "-bold-italic"] ] ++ ["mono"]

-- | The advance of a code point, in glyph units.
advance :: Face -> Char -> Int
advance f c = IM.findWithDefault (faceDefault f) (ord c) (faceGlyphs f)
{-# INLINE advance #-}

-- | The kern of an ordered pair, in glyph units (0 if none).
kernPair :: Face -> Char -> Char -> Int
kernPair f a b = IM.findWithDefault 0 (kernKey (ord a) (ord b)) (faceKerns f)

-- | Sum of advances plus kerns of a run of characters, in glyph units.
textUnits :: Face -> String -> Int
textUnits _ [] = 0
textUnits f (c : cs) = advance f c + go c cs
  where
    go _ [] = 0
    go p (x : xs) = advance f x + kernPair f p x + go x xs

-- | The width of a box: units are summed (kerns included) and scaled once.
textWidth :: Face -> Int -> String -> Int
textWidth f size s = scale (textUnits f s) size

-- | Width of a single character at a size.
charWidth :: Face -> Int -> Char -> Int
charWidth f size c = scale (advance f c) size
