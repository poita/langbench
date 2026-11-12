module FloatSpec (spec) where

import Data.Text (unpack)
import Test.Hspec
import Test.QuickCheck

import Toml.Internal.Float

spec :: Spec
spec = do
  it "formats like printf %.16e" $ do
    map (unpack . formatFloat) [1, 0.1, 6.626e-34, 1e308, 5e-324, 123456789.125, -2.5]
      `shouldBe`
        [ "1.0000000000000000e+00", "1.0000000000000001e-01", "6.6259999999999998e-34"
        , "1.0000000000000000e+308", "4.9406564584124654e-324", "1.2345678912500000e+08"
        , "-2.5000000000000000e+00" ]
  it "formats special values" $ do
    unpack (formatFloat (1 / 0)) `shouldBe` "inf"
    unpack (formatFloat (-1 / 0)) `shouldBe` "-inf"
    unpack (formatFloat (0 / 0)) `shouldBe` "nan"
    unpack (formatFloat (-0.0)) `shouldBe` "-0.0000000000000000e+00"
  it "converts decimal text with correct rounding" $ do
    decimalToDouble 1 (-6) `shouldBe` 1e-6
    decimalToDouble 5 (-324) `shouldBe` 5e-324
    decimalToDouble 17976931348623157 292 `shouldBe` 1.7976931348623157e308
    decimalToDouble 17976931348623159 292 `shouldBe` (1 / 0)
    decimalToDouble 1 (-400) `shouldBe` 0
    decimalToDouble 9007199254740993 0 `shouldBe` 9007199254740992
  it "round-trips every finite double through its 17-digit text" $
    property $ \d -> not (isNaN d || isInfinite d) ==>
      let t = unpack (formatFloat (abs d))
          (mant, 'e' : ex) = break (== 'e') t
          digits = filter (/= '.') mant
          e10 = read (dropWhile (== '+') ex) - 16 :: Integer
      in decimalToDouble (read digits) e10 === abs d
