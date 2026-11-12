{-# LANGUAGE OverloadedStrings #-}
module JsonSpec (spec) where

import qualified Data.Map as M
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec
import Test.QuickCheck

import JsonSchema.Json
import JsonSchema.Number

parse :: Text -> Value
parse t = either (error . show) id (parseJson t)

genValue :: Int -> Gen Value
genValue depth =
  oneof $
    [ pure Null
    , Bool <$> arbitrary
    , (\m e -> Num (mkNumber m e)) <$> arbitrary <*> choose (-5, 5)
    , Str . T.pack <$> listOf (elements ("ab\"\\\n\t é💩" :: String))
    ]
      ++ [ Arr <$> resize 4 (listOf sub) | depth > 0 ]
      ++ [ Obj . M.fromList <$> resize 4 (listOf ((,) <$> (T.pack <$> listOf1 (elements "abc")) <*> sub)) | depth > 0 ]
  where
    sub = genValue (depth - 1)

spec :: Spec
spec = do
  it "parses scalars" $ do
    parse "null" `shouldBe` Null
    parse " true " `shouldBe` Bool True
    parse "\"a\\u00e9\\ud83d\\udca9\"" `shouldBe` Str "a\233\128169"

  it "keeps numbers exact" $ do
    parse "1.0" `shouldBe` parse "1"
    parse "1e2" `shouldBe` parse "100"
    parse "-0" `shouldBe` parse "0"
    parse "0.30" `shouldBe` Num (mkNumber 3 (-1))
    parse "1E+400" `shouldBe` Num (mkNumber 1 400)

  it "treats objects as unordered" $
    parse "{\"a\":1,\"b\":2}" `shouldBe` parse "{\"b\":2,\"a\":1}"

  it "does not confuse types" $ do
    parse "true" `shouldNotBe` parse "1"
    parse "[1]" `shouldNotBe` parse "{\"0\":1}"

  it "rejects malformed documents" $ do
    parseJson "[1,]" `shouldSatisfy` isLeft'
    parseJson "{\"a\" 1}" `shouldSatisfy` isLeft'
    parseJson "01" `shouldSatisfy` isLeft'
    parseJson "1 2" `shouldSatisfy` isLeft'
    parseJson "\"\\x\"" `shouldSatisfy` isLeft'
    parseJson "" `shouldSatisfy` isLeft'

  it "round-trips through the renderer" $
    forAll (genValue 3) $ \v -> parseJson (renderJson v) == Right v

  it "hashes equal values equally" $ do
    hashValue (parse "{\"a\":1.0,\"b\":[2e0]}") `shouldBe` hashValue (parse "{\"b\":[2],\"a\":1}")
  where
    isLeft' = either (const True) (const False)
