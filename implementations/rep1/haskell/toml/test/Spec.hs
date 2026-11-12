module Main (main) where

import Test.Hspec

import qualified DecodeSpec
import qualified EncodeSpec
import qualified FloatSpec
import qualified JsonSpec
import qualified RoundTripSpec

main :: IO ()
main = hspec $ do
  describe "Decode" DecodeSpec.spec
  describe "Encode" EncodeSpec.spec
  describe "Float" FloatSpec.spec
  describe "Json" JsonSpec.spec
  describe "RoundTrip" RoundTripSpec.spec
