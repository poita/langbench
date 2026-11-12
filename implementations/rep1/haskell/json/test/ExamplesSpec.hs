{-# LANGUAGE OverloadedStrings #-}
module ExamplesSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as BL
import Test.Hspec

import Json.Canon

canon :: BS.ByteString -> Maybe BS.ByteString
canon = either (const Nothing) (Just . BL.toStrict) . canonicalize

-- | Input text given as bytes of a Haskell String (code points < 256 map to
-- bytes); for non-ASCII use the ByteString literals directly.
ok :: BS.ByteString -> BS.ByteString -> Spec
ok i o = it (show i) $ canon i `shouldBe` Just o

invalid :: BS.ByteString -> Spec
invalid i = it ("rejects " ++ show (BS.take 60 i)) $ canon i `shouldBe` Nothing

spec :: Spec
spec = do
  describe "valid documents" $ do
    ok "{ \"b\": [1, 2.50, 1E+3], \"a\": \"h\xc3\xa9llo\\/\", \"b\": null }"
       "{\"a\":\"h\xc3\xa9llo/\",\"b\":null}"
    ok "[\"\xf0\x9f\x98\x80\", -0, 1e-007, 0.0, 1e-0, \"tab\\tquote\\\"nul\\u0000 A\\u0041\"]"
       "[\"\xf0\x9f\x98\x80\",-0,1e-7,0.0,1e0,\"tab\\tquote\\\"nul\\u0000 AA\"]"
    ok "\"\\u007f\\/\\u2028\\uD83D\\uDE00\"" "\"\x7f/\xe2\x80\xa8\xf0\x9f\x98\x80\""
    ok "{\"\\uE000\":1,\"\xf0\x9f\x98\x80\":2,\"\\uFFFF\":3,\"Z\":4}"
       "{\"Z\":4,\"\xf0\x9f\x98\x80\":2,\"\xee\x80\x80\":1,\"\xef\xbf\xbf\":3}"
    ok " \t\r\n[ ]\n" "[]"
    ok "{}" "{}"
    ok "123456789012345678901234567890" "123456789012345678901234567890"
    ok "-0" "-0"
    ok "1E5" "1e5"
    ok "1e+05" "1e5"
    ok "1E+00" "1e0"
    ok "-0.0" "-0.0"
    ok "0e0" "0e0"
    ok "2.5E-000789" "2.5e-789"
    ok "\"\\u001f\\b\\f\\n\\r\\t\\\"\\\\\"" "\"\\u001f\\b\\f\\n\\r\\t\\\"\\\\\""
    ok "{\"a\":1,\"b\":2,\"a\":3}" "{\"a\":3,\"b\":2}"
    ok "{\"\\u0061\":1,\"a\":2}" "{\"a\":2}"
    ok "{\"aa\":1,\"a\\u0000\":2,\"a\":3,\"\":4}" "{\"\":4,\"a\":3,\"a\\u0000\":2,\"aa\":1}"
    ok (BS.concat (replicate 512 "[") <> BS.concat (replicate 512 "]"))
       (BS.concat (replicate 512 "[") <> BS.concat (replicate 512 "]"))

  describe "invalid documents" $ do
    mapM_ invalid
      [ "", "   ", "\xef\xbb\xbf[]", "[1, 2, ]", "[1,]", "{\"a\":1,}", "[,1]", "[1 2]"
      , "{\"a\" 1}", "{a:1}", "{1:1}", "'a'", "[1] x", "[1]\0", "\x0c[1]", "\x0b[1]"
      , "True", "NaN", "Infinity", "-Infinity", "nul", "nulll", "truee"
      , "01", "+1", "-", "1.", ".5", "1e", "1e+", "1E+-5", "1e5e5", "0x1", "- 1", "1 .5"
      , "[\xd9\xa2]", "\"\\x\"", "\"\\U0041\"", "\"\\'\"", "\"\\0\"", "\"\\u12\""
      , "\"\\u00G0\"", "\"\\u\xef\xbc\x91\xef\xbc\x91\xef\xbc\x91\xef\xbc\x91\"", "[\"\\"
      , "\"\\uD800\"", "\"\\uD800\\u0041\"", "\"\\uD800\\uE000\"", "\"\\uD800\\uDBFF\""
      , "\"\\uD800x\"", "\"\\uDC00\"", "{\"\\uD800\":1}"
      , "{\"a\":\"\\uD800\",\"a\":1}", "{\"a\":[1,],\"a\":1}"
      , "\"a\tb\"", "\"a\nb\"", "\"\0\"", "\"abc"
      , "\"\xc0\x80\"", "\"\xed\xa0\x80\"", "\"\xf4\x90\x80\x80\"", "\"\xe2\x82\"", "\"\xff\"", "\"\x80\""
      , "\xc2\xa0[]", "[]\xe2\x80\xa8", "\xc2\x85[]"
      , BS.concat (replicate 513 "[") <> BS.concat (replicate 513 "]")
      , BS.concat (replicate 512 "[") <> "{}" <> BS.concat (replicate 512 "]")
      , "{\"a\":" <> BS.concat (replicate 513 "[") <> "],\"a\":1}"
      , BS.concat (replicate 100000 "[")
      ]

  describe "API" $ do
    it "parse keeps duplicate keys in input order" $
      parse (B8.pack "{\"a\":1,\"a\":2}") `shouldBe` Right (Object [("a", Number "1"), ("a", Number "2")])
    it "parse stores decoded strings" $
      parse (B8.pack "\"\\u0041\\uD83D\\uDE00\"") `shouldBe` Right (String "A\x1F600")
    it "reports the offset of the error" $
      either (Just . errorOffset) (const Nothing) (parse "[1,]") `shouldBe` Just 3
