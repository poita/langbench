module Main (main) where

import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Lazy.Char8 as LC
import Data.Word (Word32)
import GHC.Float (castFloatToWord32, castWord32ToFloat)
import Test.Hspec
import Test.QuickCheck

import Numeric.SoftFloat
import Numeric.SoftFloat.Internal.Ops (isqrt)
import Numeric.SoftFloat.Protocol

-- | Hardware reference (tests only), with NaNs canonicalised.
hw :: (Float -> Float -> Float) -> Word32 -> Word32 -> Word32
hw f a b = canon (castFloatToWord32 (f (castWord32ToFloat a) (castWord32ToFloat b)))

hw1 :: (Float -> Float) -> Word32 -> Word32
hw1 f a = canon (castFloatToWord32 (f (castWord32ToFloat a)))

canon :: Word32 -> Word32
canon w = if isNaN32 w then qNaN else w

-- | Bit patterns biased toward the interesting regions.
anyBits :: Gen Word32
anyBits = frequency
  [ (3, arbitraryBoundedIntegral)
  , (3, special)
  , (3, nearExp)
  , (2, (\f s -> s + f) <$> choose (0, 0x7fffff) <*> elements [0, 0x80000000])  -- denormals
  , (2, (\e f s -> s + e * 0x800000 + f) <$> choose (1, 254) <*> elements [0, 1, 2, 0x400000, 0x7ffffe, 0x7fffff]
         <*> elements [0, 0x80000000])
  ]
  where
    special = elements [0, 0x80000000, 0x7f800000, 0xff800000, 0x7fc00000, 0x7f800001,
                        0x3f800000, 0xbf800000, 1, 0x80000001, 0x00800000, 0x7f7fffff]
    nearExp = (\e f s -> s + e * 0x800000 + f) <$> choose (0, 255) <*> choose (0, 0x7fffff) <*> elements [0, 0x80000000]

-- | A pair of operands whose exponents are close, to exercise cancellation.
closePair :: Gen (Word32, Word32)
closePair = do
  a <- anyBits
  d <- choose (-3, 3) :: Gen Int
  f <- choose (0, 0x7fffff)
  s <- elements [0, 0x80000000]
  let e = fromIntegral (((a `div` 0x800000) `mod` 256)) + d
      b = s + fromIntegral (max 0 (min 255 e)) * 0x800000 + f
  pure (a, b)

prop2 :: (Word32 -> Word32 -> Word32) -> (Float -> Float -> Float) -> Property
prop2 f g = forAll (oneof [(,) <$> anyBits <*> anyBits, closePair]) $ \(a, b) -> f a b === hw g a b

main :: IO ()
main = hspec $ do
  describe "specification examples" $ do
    it "add/sub/mul/div/sqrt basics" $ do
      f32Add 0x3f800000 0x3f800000 `shouldBe` 0x40000000
      f32Sub 0x3f800000 0x3f800000 `shouldBe` 0
      f32Mul 0x40400000 0xc0400000 `shouldBe` 0xc1100000
      f32Div 0x3f800000 0x40400000 `shouldBe` 0x3eaaaaab
      f32Sqrt 0x40000000 `shouldBe` 0x3fb504f3
    it "special values and signed zeros" $ do
      f32Add 0x7f800000 0xff800000 `shouldBe` 0x7fc00000
      f32Mul 0x7f800000 0 `shouldBe` 0x7fc00000
      f32Div 0 0 `shouldBe` 0x7fc00000
      f32Sqrt 0x80000000 `shouldBe` 0x80000000
      f32Sqrt 0xbf800000 `shouldBe` 0x7fc00000
      f32Mul 0 0xbf800000 `shouldBe` 0x80000000
      f32Add 0x80000000 0x80000000 `shouldBe` 0x80000000
      f32Add 0x80000000 0 `shouldBe` 0
      f32Div 0x3f800000 0x80000000 `shouldBe` 0xff800000
      f32Add 0x7fc12345 0x3f800000 `shouldBe` 0x7fc00000
    it "rounding at the edges" $ do
      f32Add 0x7f7fffff 0x73000000 `shouldBe` 0x7f800000
      f32Add 0x7f7fffff 0x72ffffff `shouldBe` 0x7f7fffff
      f32Div 1 0x40000000 `shouldBe` 0
      f32Div 3 0x40000000 `shouldBe` 2
      f32Add 0x3f800000 0x33800000 `shouldBe` 0x3f800000
      f32Add 0x3f800001 0x33800000 `shouldBe` 0x3f800002
      f32Add 0x3f800000 0x33000000 `shouldBe` 0x3f800000
      f32Mul 1 0x3f000000 `shouldBe` 0
      f32Mul 0x80000001 0x3f000000 `shouldBe` 0x80000000
    it "denormal rounds up to the smallest normal" $
      f32Mul 0x007fffff 0x3f800001 `shouldBe` 0x00800000

  describe "isqrt" $
    it "is the floor square root with remainder" $ property $
      forAll (choose (0, 2 ^ (53 :: Int) - 1)) $ \n ->
        let (r, m) = isqrt n in (r * r + m === n) .&&. (m <= 2 * r)

  describe "against the hardware oracle" $ do
    it "add" $ withMaxSuccess 20000 $ prop2 f32Add (+)
    it "sub" $ withMaxSuccess 20000 $ prop2 f32Sub (-)
    it "mul" $ withMaxSuccess 20000 $ prop2 f32Mul (*)
    it "div" $ withMaxSuccess 20000 $ prop2 f32Div (/)
    it "sqrt" $ withMaxSuccess 20000 $ forAll anyBits $ \a -> f32Sqrt a === hw1 sqrt a

  describe "algebraic properties" $ do
    it "add commutes" $ property $ forAll ((,) <$> anyBits <*> anyBits) $ \(a, b) ->
      f32Add a b === f32Add b a
    it "mul commutes" $ property $ forAll ((,) <$> anyBits <*> anyBits) $ \(a, b) ->
      f32Mul a b === f32Mul b a
    it "never emits a NaN other than the canonical one" $ property $
      forAll ((,) <$> anyBits <*> anyBits) $ \(a, b) ->
        all (\w -> not (isNaN32 w) || w == qNaN) [f32Add a b, f32Mul a b, f32Div a b, f32Sqrt a]

  describe "Protocol" $ do
    it "parses lines" $ do
      parseLine (C.pack "add 3f800000 3f800000") `shouldBe` Right (Request Add 0x3f800000 0x3f800000)
      parseLine (C.pack "sqrt 40000000") `shouldBe` Right (Request Sqrt 0x40000000 0)
    it "rejects malformed lines" $ do
      parseLine (C.pack "add 3f800000") `shouldSatisfy` isLeft
      parseLine (C.pack "pow 3f800000 3f800000") `shouldSatisfy` isLeft
      parseLine (C.pack "add 3F800000 3f800000") `shouldSatisfy` isLeft
      parseLine (C.pack "add 3f80000 3f800000") `shouldSatisfy` isLeft
    it "processes input with and without trailing newline" $ do
      let expected = Right (LC.pack "40000000\n00000000\n")
      processInput (C.pack "add 3f800000 3f800000\nsub 3f800000 3f800000\n") `shouldBe` expected
      processInput (C.pack "add 3f800000 3f800000\nsub 3f800000 3f800000") `shouldBe` expected
  where
    isLeft (Left _) = True
    isLeft _ = False
