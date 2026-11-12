{-# LANGUAGE OverloadedStrings #-}
module EncodeSpec (spec) where

import qualified Data.Map.Strict as Map
import Test.Hspec

import Toml

spec :: Spec
spec = do
  it "writes a lone newline for the empty table" $
    encodeText Map.empty `shouldBe` "\n"
  it "writes pairs before headers, sorted, with blank lines between" $
    encodeText (Map.fromList
      [ ("name", vString "Tom")
      , ("db", VTable (Map.fromList [("enabled", vBool True), ("ports", VArray [vInteger 8001, vInteger 8002])]))
      , ("fruit", VArray [VTable (Map.fromList [("name", vString "apple")]), VTable (Map.fromList [("name", vString "banana")])])
      ])
      `shouldBe` "name = \"Tom\"\n\n[db]\nenabled = true\nports = [8001, 8002]\n\n[[fruit]]\nname = \"apple\"\n\n[[fruit]]\nname = \"banana\"\n"
  it "omits the blank line only before the first line of the document" $
    encodeText (Map.fromList [("a", VTable (Map.fromList [("b", VTable Map.empty)]))])
      `shouldBe` "[a]\n\n[a.b]\n"
  it "renders empty and mixed arrays inline" $
    encodeText (Map.fromList
      [ ("e", VArray [])
      , ("m", VArray [VTable (Map.fromList [("a", vInteger 1)]), vInteger 2])
      , ("n", VArray [VArray [vInteger 1], VArray []])
      ])
      `shouldBe` "e = []\nm = [{a = 1}, 2]\nn = [[1], []]\n"
  it "quotes keys that are not bare and escapes strings" $
    encodeText (Map.fromList
      [ ("", vString "")
      , ("a b", vString "q\"\\\b\t\n\f\r\1\DEL\233")
      , ("ok_-1", vBool False)
      ])
      `shouldBe` "\"\" = \"\"\n\"a b\" = \"q\\\"\\\\\\b\\t\\n\\f\\r\\u0001\\u007f\233\"\nok_-1 = false\n"
  it "writes scalar texts verbatim" $
    encodeText (Map.fromList
      [ ("d", VScalar TDateTime "1979-05-27T07:32:00Z")
      , ("f", vFloat 1)
      ])
      `shouldBe` "d = 1979-05-27T07:32:00Z\nf = 1.0000000000000000e+00\n"
