module Main (main) where

import qualified Data.ByteString.Char8 as BC
import Data.Maybe (fromJust)
import Numeric.BigInt
import Numeric.BigInt.Magnitude (base, fromDecimal, toDecimal)
import Numeric.BigInt.Query (evalInput, evalQuery)
import Test.Hspec
import Test.QuickCheck

-- | Parse, for tests with known-good literals.
big :: String -> BigInt
big = fromJust . parseBigInt . BC.pack

-- | Integer is used purely as a test oracle.
toI :: BigInt -> Integer
toI = read . BC.unpack . renderBigInt

fromI :: Integer -> BigInt
fromI = big . show

-- | Integers with a bias towards limb boundaries (powers of 10^9 +- 1) and
-- long digit strings, which is where carries and Algorithm D corrections hide.
newtype Wide = Wide Integer deriving (Show)

instance Arbitrary Wide where
  arbitrary = Wide <$> oneof [small, boundary, long]
    where
      b = toInteger base
      small = choose (-1000, 1000)
      boundary = do
        k <- choose (0, 6)
        d <- choose (-2, 2)
        s <- elements [1, -1]
        m <- elements [1, 2, b `div` 2, b - 1]
        pure (s * (m * b ^ (k :: Int) + d))
      long = do
        n <- choose (1, 120)
        ds <- vectorOf n (elements "0123456789999000")
        s <- elements [1, -1]
        pure (s * read ('1' : ds))
  shrink (Wide n) = Wide <$> shrink n

prop2 :: (Integer -> Integer -> Bool) -> Wide -> Wide -> Bool
prop2 f (Wide a) (Wide b) = f a b

main :: IO ()
main = hspec $ do
  describe "parsing and rendering" $ do
    it "normalises leading zeros and negative zero" $ do
      renderBigInt (big "-000") `shouldBe` BC.pack "0"
      renderBigInt (big "-000123") `shouldBe` BC.pack "-123"
      renderBigInt (big "007") `shouldBe` BC.pack "7"
    it "rejects malformed input" $ do
      parseBigInt (BC.pack "") `shouldBe` Nothing
      parseBigInt (BC.pack "-") `shouldBe` Nothing
      parseBigInt (BC.pack "+1") `shouldBe` Nothing
      parseBigInt (BC.pack "1x") `shouldBe` Nothing
    it "round-trips magnitudes of every length around limb boundaries" $
      mapM_ (\n -> let s = BC.pack ('1' : replicate n '0')
                   in toDecimal (fromDecimal s) `shouldBe` s) [0 .. 40]
    it "prints inner zero limbs padded" $
      renderBigInt (big "1000000000000000000000000001") `shouldBe` BC.pack "1000000000000000000000000001"
    it "round-trips through Integer" $ property $ \(Wide n) -> toI (fromI n) == n
    it "fromInteger / toInt" $ do
      (fromInteger (2 ^ (100 :: Int) + 5) :: BigInt) `shouldBe` big "1267650600228229401496703205381"
      (-12345 :: BigInt) `shouldBe` big "-12345"
      toInt (fromInt minBound) `shouldBe` Just minBound
      toInt (big "9223372036854775808") `shouldBe` Nothing

  describe "arithmetic agrees with Integer" $ do
    it "addition" $ property $ prop2 $ \a b -> toI (fromI a `addBig` fromI b) == a + b
    it "subtraction" $ property $ prop2 $ \a b -> toI (fromI a `subBig` fromI b) == a - b
    it "multiplication" $ property $ prop2 $ \a b -> toI (fromI a `mulBig` fromI b) == a * b
    it "comparison" $ property $ prop2 $ \a b -> compare (fromI a) (fromI b) == compare a b
    it "quotRem (C semantics)" $ withMaxSuccess 3000 $ property $ prop2 $ \a b ->
      b == 0 || fmap (\(q, r) -> (toI q, toI r)) (quotRemBig (fromI a) (fromI b)) == Just (a `quot` b, a `rem` b)
    it "quotRem invariants on larger operands" $ withMaxSuccess 1000 $ property $
      forAll (resize 300 arbitrary) $ \(Wide a0, Wide b0, Wide c0) ->
        let a = a0 * a0 * c0 * 1000000007
            b = b0 * b0 + 1
        in case quotRemBig (fromI a) (fromI b) of
             Just (q, r) -> a == toI q * b + toI r && abs (toI r) < abs b
             Nothing -> False
    it "power" $ property $ \(Wide a) (NonNegative e) ->
      let e' = e `mod` 40 in fmap toI (powBig (fromI a) (fromInt e')) == Just (a ^ e')
    it "Num instance" $ property $ \(Wide a) (Wide b) ->
      toI (fromI a * fromI b - fromI a + 3) == a * b - a + 3

  describe "division edge cases" $ do
    let qr a b = fmap (\(q, r) -> (show q, show r)) (quotRemBig (big a) (big b))
    it "signs" $ do
      qr "7" "2" `shouldBe` Just ("3", "1")
      qr "-7" "2" `shouldBe` Just ("-3", "-1")
      qr "7" "-2" `shouldBe` Just ("-3", "1")
      qr "-7" "-2" `shouldBe` Just ("3", "-1")
      qr "-1" "3" `shouldBe` Just ("0", "-1")
      qr "-7" "7" `shouldBe` Just ("-1", "0")
    it "by zero" $ do
      qr "1" "0" `shouldBe` Nothing
      qr "0" "-000" `shouldBe` Nothing
    it "rare Algorithm D add-back cases" $ do
      let b = 10 ^ (9 :: Int) :: Integer
          cases =
            [ (b ^ (3 :: Int) , b ^ (2 :: Int) - 1)
            , (b ^ (4 :: Int) - 1, b ^ (2 :: Int) - 1)
            , (b ^ (4 :: Int) - 1, b ^ (2 :: Int) `div` 2 + 1)
            , ((b `div` 2) * b ^ (3 :: Int) + (b ^ (2 :: Int) - 1), (b `div` 2) * b + (b - 1))
            , (b ^ (5 :: Int) - b ^ (3 :: Int), b ^ (3 :: Int) - b + 1)
            ]
      mapM_ (\(x, y) -> fmap (\(q, r) -> (toI q, toI r)) (quotRemBig (fromI x) (fromI y))
                          `shouldBe` Just (x `quot` y, x `rem` y)) cases

  describe "exponentiation" $ do
    it "zero and one exponents" $ do
      powBig (big "0") (big "0") `shouldBe` Just (big "1")
      powBig (big "0") (big "5") `shouldBe` Just (big "0")
      powBig (big "-0") (big "-00") `shouldBe` Just (big "1")
      powBig (big "-1") (big "999") `shouldBe` Just (big "-1")
      powBig (big "-1") (big "1000000000000000000000") `shouldBe` Just (big "1")
    it "negative exponent is Nothing" $ powBig (big "2") (big "-1") `shouldBe` Nothing
    it "large power" $
      renderBigInt (fromJust (powBig (big "-3") (big "1001"))) `shouldBe` BC.pack (show ((-3) ^ (1001 :: Int) :: Integer))

  describe "Query" $ do
    it "evaluates the spec examples" $
      evalInput (BC.pack "12 + 30\n5 - 7\n-7 / 2\n-7 % 2\n-0 + 0\n007 cmp 7\n-5 * 0\n2 ^ 10\n0 ^ 0\n")
        `shouldBe` BC.pack "42\n-2\n-3\n-1\n0\n0\n0\n1024\n1\n"
    it "reports errors" $
      evalInput (BC.pack "1 / 0\n0 % 0\n2 ^ -1\n5 ^ -0\n5 / -0")
        `shouldBe` BC.pack "error\nerror\nerror\n1\nerror\n"
    it "handles empty input and a missing final newline" $ do
      evalInput BC.empty `shouldBe` BC.empty
      evalInput (BC.pack "1 + 1") `shouldBe` BC.pack "2\n"
    it "rejects unknown operators" $ evalQuery (BC.pack "1 ? 2") `shouldBe` Nothing
    it "cmp" $ do
      evalQuery (BC.pack "-3 cmp -2") `shouldBe` Just (BC.pack "-1")
      evalQuery (BC.pack "-0 cmp 0") `shouldBe` Just (BC.pack "0")
      evalQuery (BC.pack "10 cmp 9") `shouldBe` Just (BC.pack "1")
