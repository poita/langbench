{-# LANGUAGE OverloadedStrings #-}

module CRCSpec (spec) where

import qualified Data.ByteString as BS
import Test.Hspec
import Test.QuickCheck
import Tessera.CRC
import Tessera.WAL (walHeader)

spec :: Spec
spec = describe "Tessera.CRC" $ do
  it "matches the specification's test vectors" $ do
    crc32 "" `shouldBe` 0
    crc32 "a" `shouldBe` 0xE8B7BE43
    crc32 "123456789" `shouldBe` 0xCBF43926
    crc32 "TESSERA1" `shouldBe` 0x2C9A9B66
    crc32 "TESSWAL1" `shouldBe` 0x7D446716
    crc32 (BS.replicate 20 0) `shouldBe` 0x0FD59B8D
    crc32 (BS.replicate 1024 0) `shouldBe` 0xEFB5AF2E
  it "is chunk-independent" $
    property $ \xs ys -> crc32Chunks [BS.pack xs, BS.pack ys] === crc32 (BS.pack (xs ++ ys))
  it "gives the log header its stored checksum" $
    BS.drop 28 walHeader `shouldBe` BS.pack [0x51, 0xe7, 0x21, 0x53]
