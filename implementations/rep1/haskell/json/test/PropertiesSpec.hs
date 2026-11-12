{-# LANGUAGE OverloadedStrings #-}
module PropertiesSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Char (chr, ord)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Test.Hspec
import Test.QuickCheck

import Json.Canon
import Json.Canon.Key (compareKeys)
import Json.Canon.Utf8 (validateUtf8)

-- | Characters biased towards the interesting boundaries.
genChar :: Gen Char
genChar = frequency
  [ (4, elements "abAZ09 /\\\"")
  , (3, chr <$> choose (0, 0x1f))
  , (2, elements "\x7f\x80\x7ff\x800\xd7ff\xe000\xffff\x10000\x10ffff\x1F600")
  , (1, chr <$> choose (0, 0xd7ff))
  , (1, chr <$> choose (0xe000, 0x10ffff))
  ]

genText :: Gen Text
genText = T.pack <$> resize 8 (listOf genChar)

-- | Reference UTF-16 code unit sequence.
utf16 :: Text -> [Int]
utf16 = concatMap unit . T.unpack
  where
    unit c
      | n < 0x10000 = [n]
      | otherwise = [0xD800 + (m `div` 0x400), 0xDC00 + (m `mod` 0x400)]
      where
        n = ord c
        m = n - 0x10000

genNumber :: Gen Text
genNumber = do
  neg <- arbitrary
  i <- oneof [pure "0", T.pack . show <$> (choose (1, 10 ^ (30 :: Int)) :: Gen Integer)]
  f <- oneof [pure "", ("." <>) . T.pack . show <$> (choose (0, 9999) :: Gen Int)]
  e <- oneof [pure "", (\s d -> "e" <> s <> T.pack (show d)) <$> elements ["", "-"] <*> (choose (1, 999) :: Gen Int), pure "e0"]
  pure ((if neg then "-" else "") <> i <> f <> e)

-- | Values in which every number is already canonical.
genValue :: Int -> Gen Value
genValue d = frequency $
  [ (2, pure Null), (2, Bool <$> arbitrary), (3, Number <$> genNumber), (3, String <$> genText) ]
  ++ [ (2, Array <$> resize 4 (listOf sub)) | d > 0 ]
  ++ [ (2, Object <$> resize 4 (listOf ((,) <$> genKey <*> sub))) | d > 0 ]
  where
    sub = genValue (d - 1)
    genKey = frequency [(3, elements ["a", "b", "aa", "\xe000", "\x1F600", ""]), (1, genText)]

-- | Independent oracle for canonical order and deduplication.
normalize :: Value -> Value
normalize (Array xs) = Array (map normalize xs)
normalize (Object ms) = Object [ (k, v) | (K k, v) <- M.toAscList (M.fromList [ (K k, normalize v) | (k, v) <- ms ]) ]
normalize v = v

newtype K = K Text deriving (Eq)
instance Ord K where compare (K a) (K b) = compare (utf16 a) (utf16 b)

genBytes :: Gen BS.ByteString
genBytes = BS.pack <$> listOf (frequency
  [ (3, choose (0, 0x7f)), (3, choose (0x80, 0xbf)), (2, choose (0xc0, 0xdf))
  , (2, choose (0xe0, 0xef)), (2, choose (0xf0, 0xf4)), (1, choose (0xf5, 0xff))
  , (2, elements [0xe0, 0xed, 0xf0, 0xf4, 0x80, 0x9f, 0xa0, 0x90, 0x8f]) ])

spec :: Spec
spec = do
  it "compareKeys agrees with UTF-16 code unit order" $
    forAll genText $ \a -> forAll genText $ \b ->
      compareKeys a b === compare (utf16 a) (utf16 b)
  it "validateUtf8 agrees with the text package's decoder" $
    forAll genBytes $ \bs ->
      (validateUtf8 bs == Nothing) === either (const False) (const True) (TE.decodeUtf8' bs)
  it "render then parse yields the normalised value" $
    forAll (sized (genValue . min 4)) $ \v ->
      fmap normalize (parse (BL.toStrict (renderLazy v))) === Right (normalize v)
  it "canonical output is a fixed point" $
    forAll (sized (genValue . min 4)) $ \v ->
      let out = BL.toStrict (renderLazy v)
       in fmap BL.toStrict (canonicalize out) === Right (BL.toStrict (renderLazy (normalize v)))
  it "parse is total and a successful parse implies valid UTF-8" $
    forAll genBytes $ \bs -> case parse bs of
      Right _ -> validateUtf8 bs === Nothing
      Left _ -> property True
  it "inserting whitespace between tokens does not change the result" $
    forAll (sized (genValue . min 3)) $ \v ->
      let out = BL.toStrict (renderLazy v)
          spaced = BS.concatMap (\w -> if w `elem` [0x2c, 0x3a, 0x5b, 0x5d, 0x7b, 0x7d] then BS.pack [0x20, w, 0x0a] else BS.singleton w) out
       in -- only valid if no structural byte lies inside a string, so compare via the tree
          case (parse out, parse spaced) of
            (Right a, Right b) | not (BS.any (`elem` [0x2c, 0x3a, 0x5b, 0x5d, 0x7b, 0x7d]) (strBytes v)) -> a === b
            _ -> property True

-- | All string bytes of a value (keys and values), to skip the whitespace
-- property when structural bytes appear inside strings.
strBytes :: Value -> BS.ByteString
strBytes v = case v of
  String t -> TE.encodeUtf8 t
  Array xs -> BS.concat (map strBytes xs)
  Object ms -> BS.concat [ TE.encodeUtf8 k <> strBytes x | (k, x) <- ms ]
  _ -> BS.empty
