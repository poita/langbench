{-# LANGUAGE OverloadedStrings #-}

module ValueSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Helpers
import Test.Hspec
import Data.Word (Word8)
import Test.QuickCheck
import Tessera.Error (ErrorKind (..))
import Tessera.IndexKey
import Tessera.Parser (parseValue)
import Tessera.Path
import Tessera.Value

instance Arbitrary Value where
  arbitrary = sized gen
    where
      gen :: Int -> Gen Value
      gen n
        | n <= 0 = scalar
        | otherwise =
            frequency
              [ (4, scalar)
              , (1, VList <$> resize 4 (listOf (gen (n `div` 2))))
              , (1, VObject . Map.fromList <$> resize 4 (listOf ((,) <$> name <*> gen (n `div` 2))))
              ]
      scalar =
        oneof
          [ pure VNull
          , VBool <$> arbitrary
          , VInt <$> arbitrary
          , VString <$> name
          ]
      name = BS.pack <$> resize 6 (listOf (elements ([0x00, 0x22, 0x5C, 0x7F, 0xC3, 0xA9] ++ [0x61 .. 0x66])))

spec :: Spec
spec = do
  describe "serialisation" $ do
    it "matches the worked examples" $ do
      serialize (VInt 1) `shouldBe` hexBytes [3, 0, 0, 0, 0, 0, 0, 0, 1]
      serialize (VInt (-1)) `shouldBe` hexBytes [3, 255, 255, 255, 255, 255, 255, 255, 255]
      serialize VNull `shouldBe` hexBytes [0]
      serialize (VString "ada") `shouldBe` hexBytes [4, 0, 0, 0, 3, 0x61, 0x64, 0x61]
      let Right doc = parseValue "{name:\"ada\",age:36,ok:true}"
      BS.length (serialize doc) `shouldBe` 44
    it "round-trips" $ property $ \v -> deserialize (serialize v) === Just v
    it "rejects trailing bytes" $ deserialize (serialize VNull <> "x") `shouldBe` Nothing
  describe "rendering" $ do
    it "is canonical" $ do
      let Right doc = parseValue "{name:\"ada\",age:36}"
      render doc `shouldBe` "{\"age\":36,\"name\":\"ada\"}"
      render (VList [VInt 1, VString "x", VNull]) `shouldBe` "[1,\"x\",null]"
      render (VObject Map.empty) `shouldBe` "{}"
    it "escapes strings" $ do
      render (VString "a\"b") `shouldBe` "\"a\\\"b\""
      render (VString "\x00\x1f\x7f\n\t/") `shouldBe` "\"\\u0000\\u001f\\u007f\\n\\t/\""
      render (VString "\xc3\xa9") `shouldBe` "\"\xc3\xa9\""
  describe "depth" $ do
    it "counts levels" $ do
      depth (VInt 1) `shouldBe` 1
      depth (VList []) `shouldBe` 1
      depth (VList [VList []]) `shouldBe` 2
  describe "paths" $ do
    let Right doc = parseValue "{a:{b:1},l:[1]}"
        p s = either (error . show) id (parsePath s)
    it "resolves through objects only" $ do
      resolve (p "a.b") doc `shouldBe` Just (VInt 1)
      resolve (p "a.c") doc `shouldBe` Nothing
      resolve (p "l.x") doc `shouldBe` Nothing
    it "limits segments and length" $ do
      parsePath "a.b.c.d.e.f.g.h.i" `shouldBe` Left BadPath
      parsePath (BS.replicate 31 0x61) `shouldBe` Left BadPath
      pathText (p "a.b") `shouldBe` "a.b"
  describe "index keys" $ do
    it "matches the worked vkeys" $ do
      valueKey VNull `shouldBe` Just (hexBytes [0x10])
      valueKey (VInt 36) `shouldBe` Just (hexBytes [0x30, 0x80, 0, 0, 0, 0, 0, 0, 0x24])
      valueKey (VInt minBound) `shouldBe` Just (hexBytes [0x30, 0, 0, 0, 0, 0, 0, 0, 0])
      valueKey (VString "a\0b") `shouldBe` Just (hexBytes [0x40, 0x61, 0, 0xff, 0x62, 0, 0])
      valueKey (VList []) `shouldBe` Nothing
    it "preserves order for integers" $
      property $ \a b -> compare (valueKey (VInt a)) (valueKey (VInt b)) === compare a b
    it "preserves order for strings" $
      property $ \(a :: [Word8]) (b :: [Word8]) ->
        compare (valueKey (VString (BS.pack a))) (valueKey (VString (BS.pack b))) === compare a b
    it "recovers the document key" $
      property $ \(a :: [Word8]) (k :: [Word8]) ->
        let Just e = entryKey (VString (BS.pack a)) (BS.pack k) in documentKeyOf e === BS.pack k
