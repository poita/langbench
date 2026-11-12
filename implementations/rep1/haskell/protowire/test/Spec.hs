{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import Data.ByteString (ByteString)
import qualified Data.Text.Encoding as TE
import Data.Word (Word8)
import Gen
import Protowire
import Protowire.Hex
import Protowire.Utf8 (isValidUtf8)
import Protowire.Wire
import Test.Hspec
import Test.QuickCheck

-- | Run a whole input (schema, @--@, requests) and return the output lines.
run :: [ByteString] -> [ByteString]
run ls = case processInput (BC.unlines ls) of
  Left e -> error (show e)
  Right b -> BC.lines (BL.toStrict (B.toLazyByteString b))

-- | Run requests against one schema, one output per request.
with :: ByteString -> [ByteString] -> [ByteString]
with schema reqs = run (schema : "--" : reqs)

main :: IO ()
main = hspec $ do
  describe "Protowire.Wire" $ do
    it "encodes minimal varints" $ do
      bytes (varint 0) `shouldBe` [0]
      bytes (varint 300) `shouldBe` [0xac, 0x02]
      bytes (varint maxBound) `shouldBe` replicate 9 0xff ++ [1]
    it "decodes non-minimal and truncated 10th bytes" $ do
      readVarint 10 "\x81\x00" 0 `shouldBe` Right (1, 2)
      readVarint 10 (BS.pack (replicate 9 0xff ++ [0x7f])) 0 `shouldBe` Right (maxBound, 10)
      readVarint 10 (BS.pack (replicate 9 0x80 ++ [0x02])) 0 `shouldBe` Right (0, 10)
    it "rejects an 11-byte varint and a cut-off varint" $ do
      readVarint 10 (BS.replicate 11 0x80) 0 `shouldBe` Left VarintTooLong
      readVarint 10 "\xff" 0 `shouldBe` Left Truncated
    it "limits tags to 5 bytes and 32 bits" $ do
      readTag (BS.pack [0x08]) 0 `shouldBe` Right (1, 0, 1)
      readTag (BS.pack [0x80, 0x80, 0x80, 0x80, 0x10]) 0 `shouldBe` Left InvalidTag
      readTag (BS.pack [0x80, 0x80, 0x80, 0x80, 0x80, 0x00]) 0 `shouldBe` Left VarintTooLong
      readTag (BS.pack [0x00]) 0 `shouldBe` Left InvalidTag
      readTag (BS.pack [0x0e]) 0 `shouldBe` Left InvalidWireType
    it "zigzags at the extremes" $ do
      zigzag32 minBound `shouldBe` maxBound
      zigzag64 minBound `shouldBe` maxBound
      map zigzag32 [0, -1, 1, -2, 2] `shouldBe` [0, 1, 2, 3, 4]
    prop' "varint round-trips and varintSize agrees" $ \w ->
      let bs = bytes (varint w)
       in readVarint 10 (BS.pack bs) 0 === Right (w, length bs) .&&. varintSize w === length bs
    prop' "unzigzag inverts zigzag" $ \a b ->
      (unzigzag32 (zigzag32 a), unzigzag64 (zigzag64 b)) === (a, b)

  describe "Protowire.Utf8" $ do
    it "accepts well-formed text" $
      mapM_ (`shouldSatisfy` isValidUtf8) ["", "abc", "\195\169", "\226\130\172", "\240\159\152\128", "\0", "\xf4\x8f\xbf\xbf"]
    it "rejects ill-formed text" $
      mapM_
        (`shouldSatisfy` (not . isValidUtf8))
        ["\xc0\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xe2\x82", "\x80", "\xff", "\xe0\x80\x80", "\xf0\x80\x80\x80"]
    prop' "agrees with the text package" $ \ws ->
      let bs = BS.pack ws
       in isValidUtf8 bs === either (const False) (const True) (TE.decodeUtf8' bs)
    prop' "agrees on valid text" $ forAll genUtf8 isValidUtf8

  describe "Protowire.Hex" $ do
    it "round-trips" $ decodeHex "00ff10" `shouldBe` Just "\x00\xff\x10"
    it "rejects odd length, uppercase and junk" $
      mapM_ ((`shouldBe` Nothing) . decodeHex) ["0", "0A", "zz", "0 "]
    prop' "decode . encode = id" $ \ws ->
      let bs = BS.pack ws
       in decodeHex (BL.toStrict (B.toLazyByteString (encodeHex bs))) === Just bs

  describe "Protowire.Schema" $ do
    it "parses compact, spread-out and recursive schemas" $ do
      let Right s = parseSchema "message A{int32 x=1;repeated A kids=2;}\nmessage\tB\r\n{\n B b = 7 ;\n}"
      messageNames s `shouldBe` ["A", "B"]
      let Just a = lookupMessage "A" s
      map fieldName (msgFields a) `shouldBe` ["x", "kids"]
      case fieldType (msgFields a !! 1) of
        FMessage m -> msgName m `shouldBe` "A"
        _ -> expectationFailure "kids should be a message"
    it "orders fields by number" $ do
      let Right s = parseSchema "message A { int32 b = 9; int32 a = 2; }"
          Just a = lookupMessage "A" s
      map fieldNumber (msgFields a) `shouldBe` [2, 9]
    it "reports unknown types" $
      parseSchema "message A { Nope x = 1; }" `shouldBe'` UnknownType "Nope"
    it "reports syntax errors" $ do
      either (const True) (const False) (parseSchema "message A { int32 x = 1 }") `shouldBe` True
      either (const True) (const False) (parseSchema "message A { int32 x = 1;") `shouldBe` True

  describe "requests: examples from the specification" $ do
    it "example 1" $
      run
        [ "message Inner { sint32 v = 1; }"
        , "message Outer {"
        , "  int32 a = 1;"
        , "  string b = 2;"
        , "  repeated int32 c = 3;"
        , "  Inner d = 4;"
        , "}"
        , "--"
        , "encode Outer {a: 1, b: \"x\", c: [1, 2], d: {v: -5}}"
        , "decode Outer 08011201781a02010222020809"
        , "encode Outer {d: {}, c: [], a: 0}"
        , "decode Outer 3800"
        , "decode Outer 08ff"
        ]
        `shouldBe` ["08011201781a02010222020809", "{a: 1, b: \"x\", c: [1, 2], d: {v: -5}}", "2200", "{}", "error"]
    it "example 2" $
      with
        "message M { uint64 u = 1; sint64 s = 2; fixed32 f = 3; bytes y = 4; repeated bool bs = 5; bool k = 6; }"
        [ "decode M 08ffffffffffffffffff0110ff011dffffffff2202000f2a03010001"
        , "decode M 3002"
        , "decode M 3d000000"
        , "encode M {k: true, y: x\"cafe\", s: -128, u: 18446744073709551615}"
        , "encode M {u: -1}"
        ]
        `shouldBe` [ "{u: 18446744073709551615, s: -128, f: 4294967295, y: x\"000f\", bs: [true, false, true]}"
                   , "{k: true}"
                   , "error"
                   , "08ffffffffffffffffff0110ff012202cafe3001"
                   , "error"
                   ]
    it "example 3 (merging, groups, escaping)" $
      with
        "message P { repeated int32 r = 1; P p = 2; string s = 3; }"
        ["decode P 0801080212020803120208041a0322095c", "decode P 1b08011c0805", "decode P 1b08011400"]
        `shouldBe` ["{r: [1, 2], p: {r: [3, 4]}, s: \"\\\"\\t\\\\\"}", "{r: [5]}", "error"]

  describe "request syntax" $ do
    let s = "message M { int32 a = 1; }"
        one r = head (with s [r])
    it "treats an empty encoding as an empty line" $ one "encode M {}" `shouldBe` ""
    it "requires exact hex framing" $
      map one ["decode M ", "decode M 0", "decode M 0A", "decode M 08 ", "decode M 08 08", "decode M", "decode M zz"]
        `shouldBe` ["error", "error", "error", "error", "error", "{}", "error"]
    it "requires an encode body" $
      map one ["encode M", "encode M ", "encode M   "] `shouldBe` ["error", "error", "error"]
    it "keeps the final request when there is no trailing newline" $
      fmap (BL.toStrict . B.toLazyByteString) (processInput "message M { int32 a = 1; }\n--\ndecode M 0801")
        `shouldBe` Right "{a: 1}\n"
    it "answers every request even after an error" $
      with s ["decode M 08", "decode M 0801"] `shouldBe` ["error", "{a: 1}"]

  describe "decoding" $ do
    let s = "message N { int32 a = 1; sint32 z = 2; repeated int32 r = 3; repeated fixed32 f = 4; N n = 5; string t = 6; bool b = 7; repeated string rs = 8; }"
        d h = head (with s ["decode N " <> h])
    it "truncates int32 and sign-extends" $ do
      d "08ffffffffffffffffff01" `shouldBe` "{a: -1}"
      d "08808080808010" `shouldBe` "{}"
    it "treats wrong wire types as unknown fields" $ do
      d "0d00000000" `shouldBe` "{}"
      d "0a0101" `shouldBe` "{}"
    it "reads packed, unpacked and mixed repeated numerics" $ do
      d "1a0301ff01" `shouldBe` "{r: [1, 255]}"
      d "1a030102031804" `shouldBe` "{r: [1, 2, 3, 4]}"
      d "1a00" `shouldBe` "{}"
      d "1a0180" `shouldBe` "error"
      d "22050000000000" `shouldBe` "error"
      d "2204ff000000" `shouldBe` "{f: [255]}"
      d "25ff000000" `shouldBe` "{f: [255]}"
    it "merges repeated singular sub-messages" $ do
      d "2a0208012a031a0102" `shouldBe` "{n: {a: 1, r: [2]}}"
      d "2a0208012a020802" `shouldBe` "{n: {a: 2}}"
      d "2a00" `shouldBe` "{n: {}}"
    it "validates strings, but never skipped payloads" $ do
      d "3201ff" `shouldBe` "error"
      d "3202c3a9" `shouldBe` "{t: \"\195\169\"}"
      d "7a01ff" `shouldBe` "{}"
    it "skips nested groups and checks their numbers" $ do
      d "0b0b0c0c" `shouldBe` "{}"
      d "0b0c" `shouldBe` "{}"
      d "0b14" `shouldBe` "error"
      d "0c" `shouldBe` "error"
      d "0b" `shouldBe` "error"
    it "rejects bad tags and lengths" $ do
      mapM_ ((`shouldBe` "error") . d) ["00", "0e", "0f", "808080808000", "8080808010", "32ffffffff0f", "328080808080"]

  describe "encoding text" $ do
    let s = "message N { int32 a = 1; string t = 2; repeated sint32 r = 3; N n = 4; bytes y = 5; bool b = 6; uint32 u = 7; }"
        e t = head (with s ["encode N " <> t])
    it "accepts relaxed spacing and order" $ do
      e "{t:\"x\",a:1}" `shouldBe` "08011201" <> "78"
      e "  { a : 1 }  " `shouldBe` "0801"
      e "{r: [ 1 , -1 ]}" `shouldBe` "1a020201"
    it "treats explicit defaults as absent but present messages as significant" $ do
      e "{a: 0, t: \"\", y: x\"\", b: false, r: []}" `shouldBe` ""
      e "{n: {}}" `shouldBe` "2200"
    it "unescapes strings" $ do
      e "{t: \"\\xc3\\xa9\"}" `shouldBe` e "{t: \"\195\169\"}"
      e "{t: \"\\x41\\x4A\"}" `shouldBe` "12024" <> "14a"
      e "{t: \"\\q\"}" `shouldBe` "error"
      e "{t: \"\\xff\"}" `shouldBe` "error"
      e "{t: \"a\tb\"}" `shouldBe` "error"
    it "rejects what the grammar rejects" $
      mapM_
        ((`shouldBe` "error") . e)
        [ "", "{", "{a: 1", "{a: 1,}", "{,}", "{a 1}", "{a: 1 b: 2}", "{a: 1} x", "{a: 1, a: 2}", "{zz: 1}"
        , "{a: -0}", "{a: 007}", "{a: +5}", "{a: 1.0}", "{a: - 1}", "{a: 2147483648}", "{a: -2147483649}"
        , "{u: -1}", "{u: 4294967296}", "{b: 1}", "{b: True}", "{b: tr ue}", "{t: 1}", "{a: \"1\"}", "{a: []}"
        , "{r: 1}", "{r: [1,]}", "{n: 0}", "{a: {}}", "{y: x\"0\"}", "{y: x\"0A\"}", "{y: x \"00\"}", "{y: \"00\"}"
        , "{a: 1}\t", "\t{a: 1}", "{a:\t1}"
        ]
    it "accepts the integer limits" $ do
      e "{a: 2147483647}" `shouldBe` "08ffffffff07"
      e "{a: -2147483648}" `shouldBe` "0880808080f8ffffffff01"
      e "{u: 4294967295}" `shouldBe` "38ffffffff0f"

  describe "properties" $ do
    prop' "decode . encode = normalize" $ forAll genMessage $ \m ->
      (decode rootDesc . BL.toStrict =<< either (const (Left Truncated)) Right (encode rootDesc m))
        === Right (normalize m)
    prop' "parseText . renderText = normalize" $ forAll genMessage $ \m ->
      parseText rootDesc (BL.toStrict (renderText rootDesc m)) === Right (normalize m)
    prop' "re-encoding decoded bytes is stable" $ forAll genMessage $ \m ->
      case encode rootDesc m of
        Left _ -> property False
        Right bs -> case decode rootDesc (BL.toStrict bs) of
          Left _ -> property False
          Right m' -> encode rootDesc m' === Right bs
    prop' "decoding arbitrary bytes never crashes" $ \ws ->
      case decode rootDesc (BS.pack ws) of
        Left _ -> True
        Right m -> either (const False) (const True) (encode rootDesc m)
    prop' "Slot and Message equality is structural" $ forAll genMessage $ \m -> normalize (normalize m) === normalize m

bytes :: B.Builder -> [Word8]
bytes = BL.unpack . B.toLazyByteString

prop' :: Testable p => String -> p -> Spec
prop' name = it name . property

shouldBe' :: (Show a, Eq a, Show b) => Either a b -> a -> Expectation
shouldBe' (Left a) b = a `shouldBe` b
shouldBe' (Right r) _ = expectationFailure ("expected a failure, got " ++ show r)
