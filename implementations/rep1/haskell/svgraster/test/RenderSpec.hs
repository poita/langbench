module RenderSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Test.Hspec

import Graphics.SVG.Raster

-- | Render and return a pixel accessor over the PPM payload.
render :: Int -> Int -> String -> Int -> Int -> [Int]
render w h src = case renderToPPM w h src of
  Left e -> error e
  Right ppm ->
    let body = BS.drop (BS.length (BC.pack ("P6\n" ++ show w ++ " " ++ show h ++ "\n255\n"))) ppm
     in \x y -> [fromIntegral (BS.index body (3 * (y * w + x) + c)) | c <- [0 .. 2]]

close :: [Int] -> [Int] -> Bool
close a b = and (zipWith (\p q -> abs (p - q) <= 1) a b)

spec :: Spec
spec = do
  describe "renderToPPM" $ do
    it "writes a P6 header and exactly W*H*3 bytes" $ do
      let Right ppm = renderToPPM 3 2 "<svg/>"
      BS.take 11 ppm `shouldBe` BC.pack "P6\n3 2\n255\n"
      BS.length ppm `shouldBe` 11 + 18
      BS.all (== 255) (BS.drop 11 ppm) `shouldBe` True
    it "rejects a document whose root is not svg" $ do
      renderToPPM 1 1 "<html/>" `shouldSatisfy` either (const True) (const False)
      renderToPPM 1 1 "" `shouldSatisfy` either (const True) (const False)

    it "reproduces the fractional-edge rectangle of SPEC 10.1" $ do
      let px = render 8 4 "<svg viewBox=\"0 0 8 4\" width=\"8\" height=\"4\"><rect x=\"1\" y=\"1\" width=\"3.5\" height=\"2\" fill=\"#0000ff\"/></svg>"
      map (\x -> px x 1) [0 .. 7]
        `shouldBe` [[255, 255, 255], [0, 0, 255], [0, 0, 255], [0, 0, 255], [128, 128, 255], [255, 255, 255], [255, 255, 255], [255, 255, 255]]
      px 2 0 `shouldBe` [255, 255, 255]

    it "draws a crisp scaled stroke frame (SPEC 10.2)" $ do
      let px = render 40 40 "<svg viewBox=\"0 0 10 10\"><g transform=\"scale(2)\"><rect x=\"1\" y=\"1\" width=\"3\" height=\"3\" fill=\"none\" stroke=\"black\"/></g></svg>"
      px 5 5 `shouldBe` [0, 0, 0]
      px 11 20 `shouldBe` [0, 0, 0]
      px 12 20 `shouldBe` [255, 255, 255]
      px 20 20 `shouldBe` [255, 255, 255]
      px 3 20 `shouldBe` [255, 255, 255]

    it "honours fill-rule (SPEC 10.3)" $ do
      let star rule = "<svg viewBox=\"0 0 20 20\"><path fill=\"#000\" fill-rule=\"" ++ rule ++ "\" d=\"M10 0 L16 18 L0 7 L20 7 L4 18 Z\"/></svg>"
      render 20 20 (star "nonzero") 10 9 `shouldBe` [0, 0, 0]
      render 20 20 (star "evenodd") 10 9 `shouldBe` [255, 255, 255]
      render 20 20 (star "EVENODD") 10 9 `shouldBe` [0, 0, 0]

    it "fades a group as one object (SPEC 10.4)" $ do
      let svg =
            "<svg viewBox=\"0 0 50 40\"><g opacity=\"0.5\"><rect width=\"30\" height=\"40\" fill=\"red\"/>\
            \<rect x=\"20\" width=\"30\" height=\"40\" fill=\"blue\"/></g></svg>"
          px = render 50 40 svg
      px 25 20 `shouldSatisfy` close [128, 128, 255]
      px 5 20 `shouldSatisfy` close [255, 128, 128]
    it "fades each shape separately with per-element opacity" $ do
      let svg =
            "<svg viewBox=\"0 0 50 40\"><rect width=\"30\" height=\"40\" fill=\"red\" opacity=\"0.5\"/>\
            \<rect x=\"20\" width=\"30\" height=\"40\" fill=\"blue\" opacity=\"0.5\"/></svg>"
      render 50 40 svg 25 20 `shouldSatisfy` close [128, 64, 191]

    it "applies display with style taking precedence over the attribute" $ do
      let svg = "<svg viewBox=\"0 0 2 1\"><rect width=\"1\" height=\"1\" display=\"none\" style=\"display:inline\"/>\
                \<g display=\"none\"><rect x=\"1\" width=\"1\" height=\"1\" style=\"display:inline\"/></g></svg>"
          px = render 2 1 svg
      px 0 0 `shouldBe` [0, 0, 0]
      px 1 0 `shouldBe` [255, 255, 255]

    it "inherits properties through use, with the referenced element winning" $ do
      let svg =
            "<svg viewBox=\"0 0 4 2\" xmlns:xlink=\"http://www.w3.org/1999/xlink\">\
            \<defs><rect id=\"a\" width=\"2\" height=\"2\"/><rect id=\"b\" width=\"2\" height=\"2\" fill=\"blue\"/></defs>\
            \<use xlink:href=\"#a\" fill=\"red\"/><use href=\"#b\" x=\"2\" fill=\"red\"/><use href=\"#nothing\"/></svg>"
          px = render 4 2 svg
      px 0 0 `shouldBe` [255, 0, 0]
      px 3 0 `shouldBe` [0, 0, 255]

    it "resolves currentColor against the color property" $ do
      let svg = "<svg viewBox=\"0 0 1 1\" color=\"#00ff00\"><rect width=\"1\" height=\"1\" fill=\"currentColor\"/></svg>"
      render 1 1 svg 0 0 `shouldBe` [0, 255, 0]

    it "does not render defs, symbols or unknown elements" $ do
      let svg = "<svg viewBox=\"0 0 1 1\"><defs><rect width=\"1\" height=\"1\"/></defs><symbol><rect width=\"1\" height=\"1\"/></symbol><text><rect width=\"1\" height=\"1\"/></text></svg>"
      render 1 1 svg 0 0 `shouldBe` [255, 255, 255]

    it "stretches the view box over the output" $ do
      let svg = "<svg viewBox=\"0 0 2 1\"><rect width=\"1\" height=\"1\"/></svg>"
          px = render 4 4 svg
      px 1 3 `shouldBe` [0, 0, 0]
      px 2 3 `shouldBe` [255, 255, 255]

    it "falls back to width/height, then to the output size" $ do
      render 4 4 "<svg width=\"2\" height=\"2\"><rect width=\"1\" height=\"1\"/></svg>" 1 1 `shouldBe` [0, 0, 0]
      render 4 4 "<svg width=\"2\" height=\"2\"><rect width=\"1\" height=\"1\"/></svg>" 2 2 `shouldBe` [255, 255, 255]
      render 4 4 "<svg><rect width=\"1\" height=\"1\"/></svg>" 0 0 `shouldBe` [0, 0, 0]
      render 4 4 "<svg><rect width=\"1\" height=\"1\"/></svg>" 1 1 `shouldBe` [255, 255, 255]

  describe "parseRenderList" $ do
    it "skips comments and blank lines and strips carriage returns" $
      parseRenderList "# c\r\n\n  \nlogo.svg 64 32\r\n  # x\nb.svg 1 2\n"
        `shouldBe` [RenderJob "logo.svg" 64 32, RenderJob "b.svg" 1 2]
    it "names outputs by replacing .svg with .ppm" $
      outputName (RenderJob "logo.svg" 1 1) `shouldBe` "logo.ppm"
