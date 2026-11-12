module Main (main) where

import qualified Data.ByteString.Char8 as BC
import Test.Hspec
import Test.QuickCheck

import qualified Data.BigInt as B
import qualified Data.BigInt.Magnitude as M
import Query (evalAll, evalLine)

-- The reference oracle: Haskell's built-in 'Integer'.  It is used ONLY here,
-- in the tests, never in the library.
big :: Integer -> B.BigInt
big n = case B.parse (BC.pack (show n)) of
  Just x -> x
  Nothing -> error "unparseable"

unbig :: B.BigInt -> Integer
unbig = read . BC.unpack . B.render

-- | Integers of interesting shapes: small, near limb boundaries, and long.
newtype Wide = Wide Integer deriving (Show)

instance Arbitrary Wide where
  arbitrary = Wide <$> oneof [small, boundary, long]
    where
      small = choose (-1000, 1000)
      boundary = do
        k <- choose (0, 6 :: Int)
        d <- choose (-2, 2)
        s <- elements [1, -1]
        return (s * (10 ^ (9 * k) + d))
      long = do
        n <- choose (1, 60 :: Int)
        ds <- vectorOf n (frequency [(3, choose (0, 9)), (1, elements [0, 9])])
        s <- elements [1, -1]
        return (s * foldl (\a d -> a * 10 + d) 0 ds)
  shrink (Wide n) = Wide <$> shrink n

line :: String -> String
line = BC.unpack . evalLine . BC.pack

main :: IO ()
main = hspec $ do
  describe "parse / render" $ do
    it "normalises leading zeros and negative zero" $ do
      fmap B.render (B.parse (BC.pack "-000123")) `shouldBe` Just (BC.pack "-123")
      fmap B.render (B.parse (BC.pack "-000")) `shouldBe` Just (BC.pack "0")
      fmap B.render (B.parse (BC.pack "0000")) `shouldBe` Just (BC.pack "0")
    it "rejects malformed input" $
      mapM_ (\s -> B.parse (BC.pack s) `shouldBe` Nothing) ["", "-", "+1", "1 ", "1e5", "--1", "0x1"]
    it "round-trips" $ property $ \(Wide n) -> unbig (big n) == n
    it "round-trips a 50000-digit number" $ do
      let s = BC.pack (take 50000 (cycle "1234567890"))
      fmap B.render (B.parse s) `shouldBe` Just s

  describe "limb boundaries" $ do
    it "carries across limbs" $
      unbig (B.add (big 999999999) (big 1)) `shouldBe` 1000000000
    it "borrows across limbs" $
      unbig (B.sub (big 1000000000000000000) (big 1)) `shouldBe` 999999999999999999
    it "keeps interior zero limbs when printing" $
      B.render (big 1000000000000000001) `shouldBe` BC.pack "1000000000000000001"

  describe "arithmetic agrees with Integer" $ do
    it "add" $ property $ \(Wide a) (Wide b) -> unbig (B.add (big a) (big b)) === a + b
    it "sub" $ property $ \(Wide a) (Wide b) -> unbig (B.sub (big a) (big b)) === a - b
    it "mul" $ property $ \(Wide a) (Wide b) -> unbig (B.mul (big a) (big b)) === a * b
    it "compare" $ property $ \(Wide a) (Wide b) -> compare (big a) (big b) === compare a b
    it "quotRem" $ property $ \(Wide a) (Wide b) ->
      b /= 0 ==> case B.quotRem (big a) (big b) of
        Just (q, r) -> (unbig q, unbig r) === (a `quot` b, a `rem` b)
        Nothing -> counterexample "unexpected Nothing" False
    it "quotRem satisfies the division identity" $ property $ \(Wide a) (Wide b) ->
      b /= 0 ==> case B.quotRem (big a) (big b) of
        Just (q, r) -> B.add (B.mul q (big b)) r === big a
        Nothing -> property False
    it "pow" $ property $ \(Wide a) (NonNegative e) ->
      let e' = e `mod` 12 in (unbig <$> B.pow (big a) (big e')) === Just (a ^ e')
    it "negate/abs/signum" $ property $ \(Wide a) ->
      (unbig (B.negate (big a)), unbig (B.abs (big a)), toInteger (B.signum (big a)))
        === (negate a, abs a, signum a)
    it "fromInt/toInt" $ property $ \n ->
      (B.toInt (B.fromInt n), unbig (B.fromInt n)) === (Just n, toInteger n)

  describe "division edge cases" $ do
    it "exercises the add-back correction of Algorithm D" $ do
      -- Classic hard case: divisor with top limbs 10^9/2 and a dividend that
      -- makes the first quotient estimate one too large.
      let b = 10 ^ (27 :: Int) `div` 2 + 1 :: Integer
          a = b * (10 ^ (18 :: Int) - 1) + (b - 1)
      (unbig <$> B.quot (big a) (big b), unbig <$> B.rem (big a) (big b))
        `shouldBe` (Just (a `quot` b), Just (a `rem` b))
    it "handles many-limb random-ish operands" $ do
      let a = product [1 .. 300 :: Integer]
          b = product [1 .. 120 :: Integer] + 12345
      (unbig <$> B.quot (big a) (big b), unbig <$> B.rem (big a) (big b))
        `shouldBe` (Just (a `quot` b), Just (a `rem` b))
    it "returns Nothing for a zero divisor" $
      B.quotRem (big 5) B.zero `shouldBe` Nothing
    it "never produces negative zero" $ do
      B.render <$> B.rem (big (-7)) (big 7) `shouldBe` Just (BC.pack "0")
      B.render <$> B.quot (big (-1)) (big 2) `shouldBe` Just (BC.pack "0")

  describe "pow" $ do
    it "0^0 = 1, a^0 = 1" $ do
      B.render <$> B.pow B.zero B.zero `shouldBe` Just (BC.pack "1")
      B.render <$> B.pow (big (-9)) B.zero `shouldBe` Just (BC.pack "1")
    it "signs follow exponent parity" $ do
      unbig <$> B.pow (big (-2)) (big 3) `shouldBe` Just (-8)
      unbig <$> B.pow (big (-2)) (big 2) `shouldBe` Just 4
    it "rejects negative exponents" $
      B.pow (big 2) (big (-1)) `shouldBe` Nothing
    it "answers 0, 1, -1 for huge exponents" $ do
      let e = B.mul (big (10 ^ (40 :: Int))) (big 3)
      unbig <$> B.pow (big (-1)) e `shouldBe` Just 1
      unbig <$> B.pow (big (-1)) (B.add e B.one) `shouldBe` Just (-1)
    it "computes 3^5000" $
      unbig <$> B.pow (big 3) (big 5000) `shouldBe` Just (3 ^ (5000 :: Int))

  describe "Magnitude" $ do
    it "keeps the no-high-zero-limb invariant" $
      M.toLimbs (M.fromLimbs [5, 0, 0]) `shouldBe` [5]
    it "toInt detects overflow" $ do
      M.toInt (M.fromInt maxBound) `shouldBe` Just maxBound
      M.toInt (M.add (M.fromInt maxBound) M.one) `shouldBe` Nothing

  describe "Show" $
    it "parenthesises negatives in argument position" $
      showsPrec 11 (big (-5)) "" `shouldBe` "(-5)"

  describe "CLI query evaluation" $ do
    it "matches SPEC example 1" $
      map BC.unpack (evalAll (BC.pack "12 + 30\n5 - 7\n-7 / 2\n-7 % 2\n"))
        `shouldBe` ["42", "-2", "-3", "-1"]
    it "matches SPEC example 2 (no trailing newline)" $
      map BC.unpack (evalAll (BC.pack "-0 + 0\n007 cmp 7\n-5 * 0\n99999999999999999999 + 1\n2 ^ 10\n0 ^ 0"))
        `shouldBe` ["0", "0", "0", "100000000000000000000", "1024", "1"]
    it "reports errors" $
      map line ["1 / 0", "0 % 0", "2 ^ -1", "5 / -0"] `shouldBe` replicate 4 "error"
    it "treats negative zero exponents as zero" $
      map line ["5 ^ -0", "-0 ^ -00"] `shouldBe` ["1", "1"]
    it "implements cmp" $
      map line ["-3 cmp -2", "2 cmp -3", "-0 cmp 000", "7 cmp 7"] `shouldBe` ["-1", "1", "0", "0"]
    it "truncates toward zero" $
      map line ["7 / -2", "-7 / -2", "7 % -2", "-7 % -2", "-1 % 3"]
        `shouldBe` ["-3", "3", "1", "-1", "-1"]
    it "prints nothing for empty input" $
      evalAll BC.empty `shouldBe` []
