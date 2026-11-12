{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE OverloadedStrings #-}

module ValueSpec (spec) where

import Data.List (sortBy)
import qualified Data.Text as T
import Test.Hspec
import Test.QuickCheck

import MiniSQL.Hash
import MiniSQL.Like
import MiniSQL.Value

instance Arbitrary Value where
  arbitrary =
    oneof
      [ pure VNull
      , VInt <$> arbitrary
      , VText . T.pack <$> listOf (elements "abAB_%é1")
      , VReal <$> arbitrary
      ]

spec :: Spec
spec = do
  describe "compareValues" $ do
    it "orders NULL < numbers < text" $ do
      compareValues VNull (VInt minBound) `shouldBe` LT
      compareValues (VInt 100) (VText "0") `shouldBe` LT
      compareValues (VReal 5000) (VText "") `shouldBe` LT
    it "compares text by code point" $ do
      compareValues (VText "B") (VText "a") `shouldBe` LT
      compareValues (VText "") (VText "a") `shouldBe` LT
      compareValues (VText "ab") (VText "b") `shouldBe` LT
    it "compares an INTEGER with a REAL numerically" $
      compareValues (VInt 2) (VReal 200) `shouldBe` EQ
    it "is antisymmetric" $
      property $ \a b -> compareValues a b == flipOrd (compareValues b a)
    it "is transitive" $
      property $ \a b c ->
        let sorted = sortBy compareValues [a, b, c]
         in and (zipWith (\x y -> compareValues x y /= GT) sorted (drop 1 sorted))

  describe "renderValue" $ do
    it "prints each kind of value" $ do
      map renderValue [VNull, VInt (-3), VText "hi", VReal 450, VReal (-113), VReal 0, VReal 5]
        `shouldBe` ["NULL", "-3", "hi", "4.50", "-1.13", "0.00", "0.05"]

  describe "likeMatch" $ do
    let m p s = likeMatch p s
    it "treats % as any run and _ as one character" $ do
      m "a%" "abc" `shouldBe` True
      m "%" "" `shouldBe` True
      m "_" "" `shouldBe` False
      m "a_c" "abc" `shouldBe` True
      m "a%c%e" "abxcde" `shouldBe` True
      m "%a" "ba" `shouldBe` True
      m "%a" "bab" `shouldBe` False
    it "must match the whole string" $
      m "ab" "abc" `shouldBe` False
    it "folds ASCII case only" $ do
      m "apple" "APPLE" `shouldBe` True
      m "é" "É" `shouldBe` False
    it "backtracks to the last % correctly" $ do
      m "%ab%ab" "xababab" `shouldBe` True
      m "%aab" "aaab" `shouldBe` True
      m "%a_b" "aaab" `shouldBe` True
    it "agrees with a naive matcher" $
      property $ \(PatChars p) (SubjChars s) -> likeMatch (T.pack p) (T.pack s) == naive p s

  describe "hashKey" $
    it "hashes equal keys equally" $
      property $ \(vs :: [Value]) -> hashKey vs == hashKey vs
  describe "HashTable" $
    it "keeps payloads in insertion order per key" $ do
      let t = fromPairs [([VInt 1], 'a'), ([VInt 2], 'b'), ([VInt 1], 'c'), ([VText "x"], 'd')]
      lookupAll [VInt 1] t `shouldBe` "ac"
      lookupAll [VText "x"] t `shouldBe` "d"
      lookupAll [VInt 3] t `shouldBe` ""
  where
    flipOrd LT = GT
    flipOrd GT = LT
    flipOrd EQ = EQ

newtype PatChars = PatChars String deriving (Show)
newtype SubjChars = SubjChars String deriving (Show)

instance Arbitrary PatChars where
  arbitrary = PatChars <$> listOf (elements "ab%_AB")
instance Arbitrary SubjChars where
  arbitrary = SubjChars <$> listOf (elements "abAB")

-- | Exponential-time reference implementation of LIKE.
naive :: String -> String -> Bool
naive [] s = null s
naive ('%' : ps) s = any (naive ps) (suffixes s)
  where
    suffixes xs = xs : case xs of [] -> []; (_ : r) -> suffixes r
naive (p : ps) (c : cs) = (p == '_' || lower p == lower c) && naive ps cs
  where
    lower x = if x >= 'A' && x <= 'Z' then toEnum (fromEnum x + 32) else x
naive _ [] = False
