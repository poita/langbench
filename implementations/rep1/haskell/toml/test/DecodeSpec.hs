{-# LANGUAGE OverloadedStrings #-}
module DecodeSpec (spec) where

import qualified Data.ByteString as B
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Test.Hspec

import Toml

-- | Decode and fetch a key of the root table.
get :: Text -> Text -> Maybe Value
get doc k = either (const Nothing) (Map.lookup k) (decodeText doc)

ok :: Text -> Expectation
ok doc = decodeText doc `shouldSatisfy` either (const False) (const True)

bad :: Text -> Expectation
bad doc = decodeText doc `shouldSatisfy` either (const True) (const False)

scalar :: ScalarType -> Text -> Maybe Value
scalar t = Just . VScalar t

spec :: Spec
spec = do
  describe "scalars" $ do
    it "decodes strings with escapes" $
      get "a = \"x\\t\\u00e9\\U0001F600\\\\\"" "a" `shouldBe` scalar TString "x\t\233\128512\\"
    it "decodes literal strings" $
      get "a = 'C:\\path'" "a" `shouldBe` scalar TString "C:\\path"
    it "decodes multi-line basic strings" $ do
      get "a = \"\"\"\nx\ny\"\"\"" "a" `shouldBe` scalar TString "x\ny"
      get "a = \"\"\"x \\\n   y\"\"\"" "a" `shouldBe` scalar TString "x y"
      get "a = \"\"\"x\"\"\"\"\"" "a" `shouldBe` scalar TString "x\"\""
    it "normalises CRLF inside multi-line strings" $
      get "a = '''\r\nx\r\ny'''" "a" `shouldBe` scalar TString "x\ny"
    it "prints integers in decimal" $ do
      get "a = 0xdead_beef" "a" `shouldBe` scalar TInteger "3735928559"
      get "a = 0o17" "a" `shouldBe` scalar TInteger "15"
      get "a = 0b101" "a" `shouldBe` scalar TInteger "5"
      get "a = -9223372036854775808" "a" `shouldBe` scalar TInteger "-9223372036854775808"
      get "a = +0" "a" `shouldBe` scalar TInteger "0"
    it "prints floats with 17 significant digits" $ do
      get "a = 3.1415" "a" `shouldBe` scalar TFloat "3.1415000000000002e+00"
      get "a = -0.0" "a" `shouldBe` scalar TFloat "-0.0000000000000000e+00"
      get "a = 5e-324" "a" `shouldBe` scalar TFloat "4.9406564584124654e-324"
      get "a = 1e-6" "a" `shouldBe` scalar TFloat "9.9999999999999995e-07"
      get "a = 1_0.0_1e+0_1" "a" `shouldBe` scalar TFloat "1.0009999999999999e+02"
      get "a = -inf" "a" `shouldBe` scalar TFloat "-inf"
      get "a = -nan" "a" `shouldBe` scalar TFloat "nan"
      get "a = 1e999" "a" `shouldBe` scalar TFloat "inf"
    it "canonicalises date-times" $ do
      get "a = 1987-07-05 17:45:00z" "a" `shouldBe` scalar TDateTime "1987-07-05T17:45:00Z"
      get "a = 1987-07-05T17:45:56.600+08:00" "a" `shouldBe` scalar TDateTime "1987-07-05T17:45:56.6+08:00"
      get "a = 1979-05-27t07:32:00-00:00" "a" `shouldBe` scalar TDateTime "1979-05-27T07:32:00Z"
      get "a = 1979-05-27T07:32:00.000" "a" `shouldBe` scalar TDateTimeLocal "1979-05-27T07:32:00"
      get "a = 07:32:00.5" "a" `shouldBe` scalar TTimeLocal "07:32:00.5"
      get "a = 1979-05-27 # comment" "a" `shouldBe` scalar TDateLocal "1979-05-27"
    it "decodes booleans" $
      get "a = true\nb = false" "b" `shouldBe` scalar TBool "false"

  describe "structure" $ do
    it "handles dotted keys, headers and arrays of tables" $
      decodeText "a.b = 1\n[c.d]\ne = 2\n[[f]]\ng = 3\n[[f]]\n[f.h]\ni = 4\n"
        `shouldBe` Right (Map.fromList
          [ ("a", VTable (Map.fromList [("b", vInteger 1)]))
          , ("c", VTable (Map.fromList [("d", VTable (Map.fromList [("e", vInteger 2)]))]))
          , ("f", VArray
              [ VTable (Map.fromList [("g", vInteger 3)])
              , VTable (Map.fromList [("h", VTable (Map.fromList [("i", vInteger 4)]))])
              ])
          ])
    it "accepts arrays with comments, newlines and a trailing comma" $
      get "a = [ 1, # one\n 2,\n]" "a" `shouldBe` Just (VArray [vInteger 1, vInteger 2])
    it "accepts inline tables" $
      get "a = { b.c = 1, d = [\n1,\n] }" "a"
        `shouldBe` Just (VTable (Map.fromList
          [ ("b", VTable (Map.fromList [("c", vInteger 1)]))
          , ("d", VArray [vInteger 1]) ]))
    it "treats equivalent quoted and bare keys as equal" $
      bad "a = 1\n\"a\" = 2"
    it "allows a header to pass through a dotted table" $
      ok "[fruit]\napple.color = \"red\"\n[fruit.apple.texture]\nsmooth = true"
    it "accepts CRLF line endings" $
      ok "a = 1\r\nb = 2\r\n"

  describe "invalid documents" $ do
    it "rejects duplicate keys and tables" $ do
      bad "a = 1\na = 2"
      bad "[a]\n[a]"
      bad "a.b = 1\n[a]"
      bad "[fruit]\napple.color = 1\n[fruit.apple]"
    it "rejects extending inline tables" $ do
      bad "a = {}\n[a.b]"
      bad "a = { b = 1 }\na.c = 2"
      bad "a = [{}]\n[[a]]"
    it "rejects malformed scalars" $ do
      mapM_ bad
        [ "a = 01", "a = 1__0", "a = _1", "a = 1_", "a = 0X1", "a = -0x1"
        , "a = .5", "a = 5.", "a = 1.e2", "a = 1e", "a = +inf1", "a = Inf"
        , "a = 9223372036854775808", "a = 0xFFFFFFFFFFFFFFFF", "a = True"
        , "a = 1987-7-05", "a = 1987-02-30", "a = 17:45", "a = 12:00:60"
        , "a = 0000-01-01", "a = 1979-05-27T07:32:00+24:00"
        , "a = \x0661\x0662", "a ="
        ]
    it "rejects malformed strings" $ do
      mapM_ bad
        [ "a = \"abc", "a = \"\\q\"", "a = \"\\uD800\"", "a = \"\\U00110000\""
        , "a = \"\"\"abc", "a = \"\"\"a\"\"\"\"\"\"", "a = 'abc\ndef'"
        , "a = \"\x01\"", "a = \"\DEL\"", "a = \"\"\"a\\ b\"\"\""
        ]
    it "rejects malformed structure" $ do
      mapM_ bad
        [ "a = 1 b = 2", "[a", "[ [a] ]", "[[a] ]", "a = [1,,2]", "a = [,1]"
        , "a = {b = 1,}", "a = {\nb = 1}", "a = {b = 1\n}", "= 1", "a.=1", "a b = 1"
        , "\"\"\"a\"\"\" = 1"
        ]
    it "rejects stray control characters and carriage returns" $ do
      bad "a = 1 # \x01"
      bad "a = 1\rb = 2"
      bad "a = \"x\ry\""
      bad "\0"
    it "rejects a byte-order mark" $
      bad "\xFEFFa = 1"
    it "rejects invalid UTF-8" $ do
      decode (B.pack [0x61, 0x3d, 0x22, 0xff, 0x22]) `shouldSatisfy` either (const True) (const False)
      decode (TE.encodeUtf8 "a = 1") `shouldBe` Right (Map.fromList [("a", vInteger 1)])
    it "reports the line of the error" $
      fmap errorLine (either Just (const Nothing) (decodeText "a = 1\nb = 2\nc = ?")) `shouldBe` Just 3
    it "copes with deeply nested documents" $ do
      let n = 300
      ok ("a = " <> T.replicate n "[" <> T.replicate n "]")
      ok ("a = " <> T.replicate n "{b=" <> "1" <> T.replicate n "}")
      ok ("[" <> T.intercalate "." (replicate n "a") <> "]\nx = 1")
