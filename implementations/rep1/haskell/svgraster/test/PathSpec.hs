module PathSpec (spec) where

import Test.Hspec
import Test.QuickCheck

import Graphics.SVG.Raster.Geometry
import Graphics.SVG.Raster.Path

spec :: Spec
spec = do
  describe "parsePathData" $ do
    it "repeats L after M" $
      parsePathData "M0 0 10 0 10 10"
        `shouldBe` [MoveTo (Point 0 0), LineTo (Point 10 0), LineTo (Point 10 10)]
    it "handles relative commands, H and V" $
      parsePathData "m1 1 h2 v3 H0 V0 z"
        `shouldBe` [ MoveTo (Point 1 1), LineTo (Point 3 1), LineTo (Point 3 4)
                   , LineTo (Point 0 4), LineTo (Point 0 0), ClosePath ]
    it "separates numbers by sign and decimal point" $
      parsePathData "M.5.5-1-1"
        `shouldBe` [MoveTo (Point 0.5 0.5), LineTo (Point (-1) (-1))]
    it "reads arc flags as single characters" $
      case parsePathData "M0 0a5 5 0 0110 10" of
        MoveTo _ : rest@(_ : _) | all isCubic rest, CubicTo _ _ e <- last rest -> e `shouldBe` Point 10 10
        other -> expectationFailure (show other)
    it "stops at the first unexpected token, keeping earlier commands" $ do
      parsePathData "M0 0 L1 1 bogus L5 5" `shouldBe` [MoveTo (Point 0 0), LineTo (Point 1 1)]
      parsePathData "M0 0 L1 1 L2" `shouldBe` [MoveTo (Point 0 0), LineTo (Point 1 1)]
      parsePathData "M0 0 L1 1 Z 5 5 L9 9" `shouldBe` [MoveTo (Point 0 0), LineTo (Point 1 1), ClosePath]
    it "converts quadratics to cubics with 2/3 controls" $
      parsePathData "M0 0 Q3 3 6 0"
        `shouldBe` [MoveTo (Point 0 0), CubicTo (Point 2 2) (Point 4 2) (Point 6 0)]
    it "reflects control points for S and T" $ do
      parsePathData "M0 0 C0 1 2 1 2 0 S4 -1 4 0"
        !! 2 `shouldBe` CubicTo (Point 2 (-1)) (Point 4 (-1)) (Point 4 0)
      parsePathData "M0 0 Q1 1 2 0 T4 0"
        !! 2 `shouldBe` CubicTo (Point (2 + 2 / 3) (-2 / 3)) (Point (4 - 2 / 3) (-2 / 3)) (Point 4 0)
    it "needs a leading M" $ parsePathData "L1 1" `shouldBe` []

  describe "arcToSegs" $ do
    it "drops an arc with equal endpoints" $
      arcToSegs (Point 1 1) 5 5 0 False True (Point 1 1) `shouldBe` []
    it "turns a zero radius into a line" $
      arcToSegs (Point 0 0) 0 5 0 False True (Point 3 4) `shouldBe` [LineTo (Point 3 4)]
    it "ends exactly at the end point" $
      property $ \(a :: (Int, Int)) (b :: (Int, Int)) (rx :: Positive Int) (ry :: Positive Int) rot large sweep ->
        let p0 = Point (fromIntegral (fst a)) (fromIntegral (snd a))
            p1 = Point (fromIntegral (fst b)) (fromIntegral (snd b))
            segs = arcToSegs p0 (fromIntegral (getPositive rx)) (fromIntegral (getPositive ry)) (fromIntegral (rot :: Int)) large sweep p1
         in p0 /= p1 ==> case last segs of
              CubicTo _ _ e -> e === p1
              LineTo e -> e === p1
              s -> counterexample (show s) False

  describe "flattenPath" $ do
    it "drops a lone MoveTo but keeps M Z" $ do
      flattenPath identity [MoveTo (Point 1 1)] `shouldBe` []
      flattenPath identity [MoveTo (Point 1 1), ClosePath] `shouldBe` [Subpath [Point 1 1] True]
    it "starts a new subpath at the start point after Z" $
      flattenPath identity [MoveTo (Point 0 0), LineTo (Point 1 0), ClosePath, LineTo (Point 0 1)]
        `shouldBe` [Subpath [Point 0 0, Point 1 0] True, Subpath [Point 0 0, Point 0 1] False]
    it "keeps circle flattening within tolerance of the circle" $
      forAll (choose (1, 300)) $ \r ->
        let pts = concatMap spPoints (flattenPath identity (ellipsePath 0 0 r r))
            dist (Point x y) = sqrt (x * x + y * y)
            -- chord midpoints are the worst case
            mids = zipWith (\(Point a b) (Point c d) -> Point ((a + c) / 2) ((b + d) / 2)) pts (drop 1 pts)
         in all (\p -> abs (dist p - r) < 0.011) (pts ++ mids)

  describe "shapes" $ do
    it "draws nothing for degenerate rectangles and ellipses" $ do
      rectPath 0 0 0 5 Nothing Nothing `shouldBe` []
      ellipsePath 0 0 3 0 `shouldBe` []
    it "makes a plain rectangle without radii" $
      length (rectPath 0 0 4 2 Nothing Nothing) `shouldBe` 5
    it "rounds corners and clamps radii to half the size" $ do
      let path = rectPath 0 0 10 4 (Just 100) Nothing
      path `shouldSatisfy` any isCubic
      head path `shouldBe` MoveTo (Point 5 0)
    it "drops an odd trailing coordinate in polylines" $
      polyPath False [0, 0, 1, 1, 2] `shouldBe` [MoveTo (Point 0 0), LineTo (Point 1 1)]
  where
    isCubic CubicTo {} = True
    isCubic _ = False
