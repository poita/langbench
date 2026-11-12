-- | A small SVG 1.1 subset rasteriser.
--
-- The pipeline, one module per stage:
--
-- * "Graphics.SVG.Raster.Xml" – XML parsing
-- * "Graphics.SVG.Raster.Parse" and "Graphics.SVG.Raster.Color" – numbers,
--   colours, transforms, style declarations
-- * "Graphics.SVG.Raster.Path" – path data, arcs, shapes, curve flattening
-- * "Graphics.SVG.Raster.Stroke" – stroke outlining
-- * "Graphics.SVG.Raster.Canvas" – anti-aliased scanline filling, compositing
--   and PPM output
-- * "Graphics.SVG.Raster.Render" – the document walk
--
-- Most users only need 'renderToPPM':
--
-- > import qualified Data.ByteString as BS
-- > import Graphics.SVG.Raster
-- >
-- > main :: IO ()
-- > main = do
-- >   let svg = "<svg viewBox='0 0 8 4'><rect x='1' y='1' width='3.5' height='2' fill='#00f'/></svg>"
-- >   case renderToPPM 8 4 svg of
-- >     Right ppm -> BS.writeFile "out.ppm" ppm
-- >     Left err -> putStrLn err
module Graphics.SVG.Raster
  ( -- * Rendering
    renderToPPM
  , blankPPM
    -- * Render lists
  , RenderJob (..)
  , parseRenderList
  , outputName
  ) where

import Control.Monad.ST (runST)
import qualified Data.ByteString as BS
import Data.List (isSuffixOf)
import Text.Read (readMaybe)

import Graphics.SVG.Raster.Canvas
import Graphics.SVG.Raster.Render
import Graphics.SVG.Raster.Xml

-- | Render SVG source text to a binary PPM (P6) image of the given pixel
-- width and height. The image is composited over opaque white.
--
-- The input is a 'String' of characters; only ASCII syntax is interpreted, so
-- a document read byte-by-byte (Latin-1) works as well as a decoded one.
-- 'Left' is returned if the text contains no element or its root is not
-- @svg@.
renderToPPM :: Int -> Int -> String -> Either String BS.ByteString
renderToPPM w h src = case parseXml src of
  Nothing -> Left "no root element"
  Just root
    | elName root /= "svg" -> Left ("root element is <" ++ elName root ++ ">, expected <svg>")
    | otherwise -> Right $ runST $ do
        cv <- newCanvas w h
        renderDocument cv root
        canvasToPPM cv

-- | An all-white PPM of the given size.
blankPPM :: Int -> Int -> BS.ByteString
blankPPM w h = runST (newCanvas w h >>= canvasToPPM)

-- | One line of @render.txt@.
data RenderJob = RenderJob
  { jobName :: FilePath
  -- ^ The SVG file name, relative to the input directory.
  , jobWidth :: Int
  , jobHeight :: Int
  }
  deriving (Eq, Show)

-- | Parse the text of a @render.txt@. Comment lines (first non-space
-- character @#@), blank lines and lines that are not @NAME WIDTH HEIGHT@ are
-- skipped; a trailing carriage return is ignored.
parseRenderList :: String -> [RenderJob]
parseRenderList = concatMap line . lines
  where
    line l = case words (filter (/= '\r') l) of
      ('#' : _) : _ -> []
      [name, w, h]
        | Just w' <- readMaybe w, Just h' <- readMaybe h, w' >= 1, h' >= 1 -> [RenderJob name w' h']
      _ -> []

-- | The output file name for a job: the name with a trailing @.svg@ replaced
-- by @.ppm@.
outputName :: RenderJob -> FilePath
outputName j = stem ++ ".ppm"
  where
    n = jobName j
    stem = if ".svg" `isSuffixOf` n then take (length n - 4) n else n
