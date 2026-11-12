module ParseSpec (spec) where

import qualified Data.Map.Strict as Map
import Test.Hspec
import Test.QuickCheck

import Graphics.SVG.Raster.Color
import Graphics.SVG.Raster.Geometry
import Graphics.SVG.Raster.Parse

spec :: Spec
spec = do
  describe "scanNumber" $ do
    it "accepts the forms of the grammar" $ do
      map parseNumber [".5", "5.", "5", "5.25", "-1e2", "+.5E-1", " 7 "]
        `shouldBe` map Just [0.5, 5, 5, 5.25, -100, 0.05, 7]
    it "rejects non-numbers" $ do
      parseNumber "." `shouldBe` Nothing
      parseNumber "e5" `shouldBe` Nothing
      parseNumber "5px" `shouldBe` Nothing
    it "does not consume an exponent without digits" $
      scanNumber "1e" `shouldBe` Just (1, "e")
    it "stops at a second decimal point" $
      parseNumberList "20.5.5e2 1-2" `shouldBe` [20.5, 50, 1, -2]
    it "round-trips shown doubles" $
      property $ \(x :: Double) ->
        not (isNaN x || isInfinite x) ==> parseNumber (show x) === Just x

  describe "parseLength" $ do
    it "allows px and surrounding space" $ do
      parseLength " 12px " `shouldBe` Just 12
      parseLength "3.5" `shouldBe` Just 3.5
    it "fails without a leading number" $ parseLength "auto" `shouldBe` Nothing

  describe "parsePaint" $ do
    it "parses hex colours" $ do
      parsePaint "#f39" `shouldBe` Just (PaintColor (RGB 255 51 153))
      parsePaint "#0A0b0C" `shouldBe` Just (PaintColor (RGB 10 11 12))
    it "parses rgb() with numbers and percentages" $ do
      parsePaint "rgb(300, -5, 127.5)" `shouldBe` Just (PaintColor (RGB 255 0 128))
      parsePaint "rgb(100% 50% 0%)" `shouldBe` Just (PaintColor (RGB 255 128 0))
    it "parses keywords case-insensitively" $ do
      parsePaint "CornflowerBlue" `shouldBe` Just (PaintColor (RGB 100 149 237))
      parsePaint "none" `shouldBe` Just PaintNone
      parsePaint "currentColor" `shouldBe` Just PaintCurrentColor
    it "has all 147 keywords" $
      length [() | n <- allNames, Just _ <- [namedColor n]] `shouldBe` 147
    it "rejects junk" $ do
      parsePaint "#12" `shouldBe` Nothing
      parsePaint "notacolour" `shouldBe` Nothing

  describe "parseOpacity" $ do
    it "clamps and accepts percentages" $ do
      parseOpacity "0.5" `shouldBe` Just 0.5
      parseOpacity "60%" `shouldBe` Just 0.6
      parseOpacity "2" `shouldBe` Just 1
      parseOpacity "-1" `shouldBe` Just 0
    it "rejects junk" $ do
      parseOpacity "0.5x" `shouldBe` Nothing
      parseOpacity "" `shouldBe` Nothing

  describe "parseTransform" $ do
    it "composes left to right" $
      applyAffine (parseTransform "translate(10 20) scale(2)") (Point 1 1) `shouldBe` Point 12 22
    it "rotates clockwise on screen" $ do
      let Point x y = applyAffine (parseTransform "rotate(90)") (Point 1 0)
      (x, y) `shouldSatisfy` \(a, b) -> abs a < 1e-12 && abs (b - 1) < 1e-12
    it "rotates about a centre" $ do
      let Point x y = applyAffine (parseTransform "rotate(180, 5, 5)") (Point 4 5)
      (x, y) `shouldSatisfy` \(a, b) -> abs (a - 6) < 1e-12 && abs (b - 5) < 1e-12
    it "skips unknown functions" $
      parseTransform "bogus(1) translate(3)" `shouldBe` translation 3 0
    it "reads matrix()" $
      parseTransform "matrix(1,2,3,4,5,6)" `shouldBe` Affine 1 2 3 4 5 6

  describe "parseStyle" $
    it "splits declarations, trims, lower-cases names and drops empties" $
      parseStyle "Fill : red ;; stroke:blue; bogus; opacity: ;fill-rule:evenodd;"
        `shouldBe` Map.fromList [("fill", "red"), ("stroke", "blue"), ("fill-rule", "evenodd")]

allNames :: [String]
allNames = words "aliceblue antiquewhite aqua aquamarine azure beige bisque black blanchedalmond blue blueviolet brown burlywood cadetblue chartreuse chocolate coral cornflowerblue cornsilk crimson cyan darkblue darkcyan darkgoldenrod darkgray darkgreen darkgrey darkkhaki darkmagenta darkolivegreen darkorange darkorchid darkred darksalmon darkseagreen darkslateblue darkslategray darkslategrey darkturquoise darkviolet deeppink deepskyblue dimgray dimgrey dodgerblue firebrick floralwhite forestgreen fuchsia gainsboro ghostwhite gold goldenrod gray grey green greenyellow honeydew hotpink indianred indigo ivory khaki lavender lavenderblush lawngreen lemonchiffon lightblue lightcoral lightcyan lightgoldenrodyellow lightgray lightgreen lightgrey lightpink lightsalmon lightseagreen lightskyblue lightslategray lightslategrey lightsteelblue lightyellow lime limegreen linen magenta maroon mediumaquamarine mediumblue mediumorchid mediumpurple mediumseagreen mediumslateblue mediumspringgreen mediumturquoise mediumvioletred midnightblue mintcream mistyrose moccasin navajowhite navy oldlace olive olivedrab orange orangered orchid palegoldenrod palegreen paleturquoise palevioletred papayawhip peachpuff peru pink plum powderblue purple red rosybrown royalblue saddlebrown salmon sandybrown seagreen seashell sienna silver skyblue slateblue slategray slategrey snow springgreen steelblue tan teal thistle tomato turquoise violet wheat white whitesmoke yellow yellowgreen"
