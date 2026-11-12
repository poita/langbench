module CanvasSpec (spec) where

import Control.Monad.ST (runST)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Test.Hspec
import Test.QuickCheck hiding (NonZero)

import Graphics.SVG.Raster.Canvas
import Graphics.SVG.Raster.Geometry

rect :: Double -> Double -> Double -> Double -> [Point]
rect x0 y0 x1 y1 = [Point x0 y0, Point x1 y0, Point x1 y1, Point x0 y1]

-- | Alpha of every pixel after filling the polygons in black.
coverage :: Int -> Int -> FillRule -> [[Point]] -> [[Double]]
coverage w h rule polys = runST $ do
  cv <- newCanvas w h
  fillPolygons cv rule (0, 0, 0) 1 polys
  sequence [sequence [(\(_, _, _, a) -> a) <$> readPixel cv x y | x <- [0 .. w - 1]] | y <- [0 .. h - 1]]

near :: Double -> Double -> Bool
near a b = abs (a - b) < 1e-9

spec :: Spec
spec = do
  it "gives exact coverage for axis-aligned edges" $ do
    let [row] = coverage 8 1 NonZero [rect 1 0 4.5 1]
    row `shouldSatisfy` and . zipWith near [0, 1, 1, 1, 0.5, 0, 0, 0]
  it "is independent of winding direction" $
    coverage 4 4 NonZero [reverse (rect 0.5 0.5 3 3)] `shouldBe` coverage 4 4 NonZero [rect 0.5 0.5 3 3]
  it "treats the nonzero and evenodd rules differently" $ do
    let outer = rect 0 0 6 6
        inner = rect 2 2 4 4
        centre rule = (coverage 6 6 rule [outer, inner] !! 3) !! 3
    centre NonZero `shouldSatisfy` near 1
    centre EvenOdd `shouldSatisfy` near 0
  it "cancels opposite windings under nonzero" $
    centre (coverage 6 6 NonZero [rect 0 0 6 6, reverse (rect 2 2 4 4)]) `shouldSatisfy` near 0
  it "approximates the area of a triangle" $ do
    let cov = coverage 10 10 NonZero [[Point 0 0, Point 10 0, Point 0 10]]
    sum (map sum cov) `shouldSatisfy` \a -> abs (a - 50) < 0.1
  it "clips to the canvas" $ do
    coverage 2 2 NonZero [rect (-5) (-5) 100 100] `shouldBe` [[1, 1], [1, 1]]
    coverage 2 2 NonZero [rect 5 5 9 9] `shouldBe` [[0, 0], [0, 0]]
  it "sums the coverage of an axis-aligned rectangle to its area" $
    forAll ((,,,) <$> choose (0, 8) <*> choose (0, 8) <*> choose (0, 8) <*> choose (0, 8)) $ \(a, b, c, d) ->
      let x0 = min a c; x1 = max a c; y0 = min b d; y1 = max b d
          cov = coverage 8 8 NonZero [rect x0 y0 x1 y1]
       in abs (sum (map sum cov) - (x1 - x0) * (y1 - y0)) <= (x1 - x0) / 64 + 1e-6
  it "composites source-over in straight RGB with accumulating alpha" $ do
    let (r, g, b, a) = runST $ do
          cv <- newCanvas 1 1
          fillPolygons cv NonZero (1, 0, 0) 0.5 [rect 0 0 1 1]
          fillPolygons cv NonZero (0, 0, 1) 0.5 [rect 0 0 1 1]
          readPixel cv 0 0
    (r, g, b, a) `shouldSatisfy` \(r', g', b', a') -> near r' 0.25 && near g' 0 && near b' 0.5 && near a' 0.75
  it "composites a layer with group opacity" $ do
    let (r, a) = runST $ do
          dst <- newCanvas 1 1
          src <- newCanvas 1 1
          fillPolygons src NonZero (1, 0, 0) 1 [rect 0 0 1 1]
          compositeLayer dst src 0.5
          (\(r', _, _, a') -> (r', a')) <$> readPixel dst 0 0
    (r, a) `shouldSatisfy` \(r', a') -> near r' 0.5 && near a' 0.5
  it "encodes a PPM over white" $ do
    let ppm = runST $ do
          cv <- newCanvas 2 1
          fillPolygons cv NonZero (0, 0, 1) 0.5 [rect 0 0 1 1]
          canvasToPPM cv
        header = BC.pack "P6\n2 1\n255\n"
    BS.take (BS.length header) ppm `shouldBe` header
    BS.unpack (BS.drop (BS.length header) ppm) `shouldBe` [128, 128, 255, 255, 255, 255]
  where
    centre cov = (cov !! 3) !! 3
