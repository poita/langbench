{-# LANGUAGE OverloadedStrings #-}
module RoundTripSpec (spec) where

import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec
import Test.QuickCheck

import Toml

genChar :: Gen Char
genChar = frequency
  [ (6, elements ['a' .. 'e'])
  , (2, elements " \"\\'#=.[]{}\n\t\r\b\f\DEL\0\1")
  , (2, elements "\233\20013\128512")
  , (1, choose ('\0', '\x10FFFF') `suchThat` (\c -> c < '\xD800' || c > '\xDFFF'))
  ]

genText :: Gen Text
genText = T.pack <$> listOf genChar

genKey :: Gen Text
genKey = frequency [(3, T.pack <$> listOf1 (elements ['a' .. 'd'])), (1, genText), (1, pure "")]

genDate :: Gen Value
genDate = oneof
  [ pure (VScalar TDateLocal "1979-05-27")
  , pure (VScalar TTimeLocal "07:32:00.25")
  , pure (VScalar TDateTimeLocal "1979-05-27T07:32:00")
  , pure (VScalar TDateTime "1979-05-27T07:32:00-08:00")
  , pure (VScalar TDateTime "1979-05-27T00:32:00Z")
  ]

genDouble :: Gen Double
genDouble = oneof
  [ arbitrary
  , (\i e -> fromIntegral (i :: Int) * 10 ^^ (e :: Int)) <$> arbitrary <*> choose (-300, 300)
  , elements [0, -0.0, 1 / 0, -1 / 0, 0 / 0, 5e-324, 1.7976931348623157e308]
  ]

genScalar :: Gen Value
genScalar = oneof
  [ vString <$> genText
  , vInteger <$> choose (-9223372036854775808, 9223372036854775807)
  , vInteger <$> arbitrary
  , vFloat <$> genDouble
  , vBool <$> arbitrary
  , genDate
  ]

genValue :: Int -> Gen Value
genValue 0 = genScalar
genValue n = frequency
  [ (4, genScalar)
  , (1, VArray <$> resize 3 (listOf (genValue (n - 1))))
  , (1, VArray <$> resize 3 (listOf1 (VTable <$> genTable (n - 1))))
  , (1, VTable <$> genTable (n - 1))
  ]

genTable :: Int -> Gen Table
genTable n = Map.fromList <$> resize 4 (listOf ((,) <$> genKey <*> genValue (n `min` 3)))

newtype Table' = Table' Table
instance Show Table' where show (Table' t) = show t

spec :: Spec
spec = do
  it "decode . encode is the identity" $
    forAll (Table' <$> genTable 3) $ \(Table' t) ->
      decodeText (encodeText t) === Right t
  it "parseTaggedJson . renderTaggedJson is the identity" $
    forAll (Table' <$> genTable 3) $ \(Table' t) ->
      parseTaggedJson (BL.toStrict (B.toLazyByteString (renderTaggedJson t))) === Right t
