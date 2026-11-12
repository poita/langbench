module StrokeSpec (spec) where

import Test.Hspec
import Test.QuickCheck

import Graphics.SVG.Raster.Geometry
import Graphics.SVG.Raster.Path (Subpath (..))
import Graphics.SVG.Raster.Stroke

style :: LineCap -> LineJoin -> StrokeStyle
style cap join = StrokeStyle 2 cap join 4 0.01

open :: [(Double, Double)] -> Subpath
open ps = Subpath [Point x y | (x, y) <- ps] False

closedPath :: [(Double, Double)] -> Subpath
closedPath ps = Subpath [Point x y | (x, y) <- ps] True

totalArea :: [[Point]] -> Double
totalArea = sum . map polygonArea

spec :: Spec
spec = do
  it "outlines one segment as a rectangle" $
    strokePieces (style CapButt JoinMiter) [open [(0, 0), (10, 0)]]
      `shouldSatisfy` \ps -> length ps == 1 && abs (totalArea ps - 20) < 1e-9
  it "adds square caps of half the width" $
    totalArea (strokePieces (style CapSquare JoinMiter) [open [(0, 0), (10, 0)]])
      `shouldSatisfy` \a -> abs (a - 24) < 1e-9
  it "adds a half disc per round cap" $
    totalArea (strokePieces (style CapRound JoinMiter) [open [(0, 0), (10, 0)]])
      `shouldSatisfy` \a -> a > 20 + pi * 0.98 && a < 20 + pi * 1.001
  it "draws a disc, a square or nothing for a single point" $ do
    strokePieces (style CapButt JoinMiter) [open [(5, 5)]] `shouldBe` []
    totalArea (strokePieces (style CapSquare JoinMiter) [open [(5, 5)]])
      `shouldSatisfy` \a -> abs (a - 4) < 1e-9
    totalArea (strokePieces (style CapRound JoinMiter) [open [(5, 5), (5, 5)]])
      `shouldSatisfy` \a -> a > 3.09 && a <= pi + 1e-9
  it "adds a miter quad at a right-angle corner" $ do
    let ps = strokePieces (style CapButt JoinMiter) [open [(0, 0), (10, 0), (10, 10)]]
    -- 2 rectangles + one join quad of area 1 (the missing corner square)
    length ps `shouldBe` 3
    totalArea ps `shouldSatisfy` \a -> abs (a - 41) < 1e-9
  it "falls back to a bevel above the miter limit" $ do
    let sharp = open [(0, 0), (10, 0), (0, 1)]
        ps = strokePieces (StrokeStyle 2 CapButt JoinMiter 2 0.01) [sharp]
        quads = [p | p <- ps, length p == 4]
    -- the two rectangles are the only quadrilaterals; the join is a triangle
    length quads `shouldBe` 2
  it "includes the closing joint of a closed subpath" $
    length (strokePieces (style CapButt JoinMiter) [closedPath [(0, 0), (4, 0), (4, 4), (0, 4)]])
      `shouldBe` 8
  it "puts the round join on the outside of a reversal" $ do
    let ps = strokePieces (style CapButt JoinRound) [open [(0, 0), (10, 0), (0, 0)]]
    -- two coincident rectangles plus a half disc beyond (10,0)
    length ps `shouldBe` 3
  it "orients every piece positively" $
    property $ \(pts :: [(Int, Int)]) closed cap join ->
      let sp = Subpath [Point (fromIntegral x) (fromIntegral y) | (x, y) <- pts] closed
          st = style (caps !! (cap `mod` 3)) (joins !! (join `mod` 3))
       in all ((> 0) . polygonArea) (strokePieces st [sp])
  where
    caps = [CapButt, CapRound, CapSquare]
    joins = [JoinMiter, JoinRound, JoinBevel]
