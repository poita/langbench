module Scheme.BigIntSpec (spec) where

import Data.Maybe (fromJust)
import Test.Hspec
import Test.QuickCheck

import Scheme.BigInt (BigInt)
import qualified Scheme.BigInt as B

-- | Decimal strings of up to ~300 digits, with biased "interesting" shapes.
newtype Big = Big BigInt deriving (Show)

instance Arbitrary Big where
  arbitrary = do
    len <- frequency [(2, choose (1, 18)), (3, choose (19, 40)), (3, choose (41, 300))]
    digits <- oneof
      [ vectorOf len (elements "0123456789")
      , pure (replicate len '9')
      , pure ('1' : replicate len '0')
      ]
    sign <- elements ["", "-"]
    pure (Big (dec (sign ++ digits)))

dec :: String -> BigInt
dec = fromJust . B.fromDecimal

spec :: Spec
spec = do
  describe "decimal conversion" $ do
    it "round-trips small values" $
      map (B.toDecimal . dec) ["0", "-0", "+5", "007", "-42"] `shouldBe` ["0", "0", "5", "7", "-42"]
    it "handles the Int boundary" $ do
      B.toDecimal (dec "9223372036854775807") `shouldBe` "9223372036854775807"
      B.toDecimal (dec "9223372036854775808") `shouldBe` "9223372036854775808"
      B.toDecimal (dec "-9223372036854775808") `shouldBe` "-9223372036854775808"
      B.toDecimal (dec "-9223372036854775809") `shouldBe` "-9223372036854775809"
    it "rejects non-numbers" $
      map B.fromDecimal ["", "-", "1a", "+"] `shouldBe` replicate 4 Nothing
    it "keeps a canonical form at the boundary" $ do
      B.add (B.fromInt maxBound) (B.fromInt 1) `shouldBe` dec "9223372036854775808"
      B.sub (dec "9223372036854775808") (B.fromInt 1) `shouldBe` B.fromInt maxBound
      B.neg (B.fromInt minBound) `shouldBe` dec "9223372036854775808"
      B.toInt (B.neg (dec "9223372036854775808")) `shouldBe` Just minBound
    it "round-trips arbitrary values" $ property $ \(Big a) ->
      dec (B.toDecimal a) === a

  describe "arithmetic" $ do
    it "computes known values" $ do
      B.toDecimal (B.mul (dec "4294967296") (dec "4294967296")) `shouldBe` "18446744073709551616"
      B.toDecimal (foldr B.mul (B.fromInt 1) (map B.fromInt [1 .. 25]))
        `shouldBe` "15511210043330985984000000"
      B.toDecimal (iterate (B.mul (B.fromInt 2)) (B.fromInt 1) !! 200)
        `shouldBe` "1606938044258990275541962092341162602522202993782792835301376"
    it "truncates division toward zero" $ do
      let qr a b = fmap (\(q, r) -> (B.toDecimal q, B.toDecimal r)) (B.quotRem (B.fromInt a) (B.fromInt b))
      qr (-7) 2 `shouldBe` Just ("-3", "-1")
      qr 7 (-2) `shouldBe` Just ("-3", "1")
      qr (-7) (-2) `shouldBe` Just ("3", "-1")
      qr minBound (-1) `shouldBe` Just ("9223372036854775808", "0")
    it "reports division by zero" $
      B.quotRem (B.fromInt 5) (B.fromInt 0) `shouldBe` Nothing
    it "divides multi-limb values (Algorithm D)" $ do
      let a = dec "340282366920938463463374607431768211455000000000000"
          b = dec "18446744073709551617"
          (q, r) = fromJust (B.quotRem a b)
      B.add (B.mul q b) r `shouldBe` a
      compare r b `shouldBe` LT
    it "orders values" $ property $ \(Big a) (Big b) ->
      compare a b === compare (B.sub a b) (B.fromInt 0)
    it "addition commutes and subtraction inverts it" $ property $ \(Big a) (Big b) ->
      B.add a b === B.add b a .&&. B.sub (B.add a b) b === a
    it "multiplication commutes, distributes and has identity" $ property $ \(Big a) (Big b) (Big c) ->
      B.mul a b === B.mul b a
        .&&. B.mul a (B.add b c) === B.add (B.mul a b) (B.mul a c)
        .&&. B.mul a (B.fromInt 1) === a
    it "quotRem satisfies a = q*b + r with |r| < |b|" $ property $ \(Big a) (Big b) ->
      not (B.isZero b) ==>
        let (q, r) = fromJust (B.quotRem a b)
            absB = if B.signum b < 0 then B.neg b else b
            absR = if B.signum r < 0 then B.neg r else r
        in B.add (B.mul q b) r === a
             .&&. counterexample "remainder too large" (absR < absB)
             .&&. counterexample "remainder sign" (B.isZero r || B.signum r == B.signum a)
    it "quotRem recovers a factor" $ property $ \(Big a) (Big b) ->
      not (B.isZero b) ==> B.quotRem (B.mul a b) b === Just (a, B.fromInt 0)
