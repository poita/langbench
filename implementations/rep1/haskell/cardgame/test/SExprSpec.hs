module SExprSpec (spec) where

import Test.Hspec
import Test.QuickCheck

import Spiremark.SExpr

-- | Generator of expressions that survive a render/parse round trip.
genExpr :: Int -> Gen SExpr
genExpr 0 = oneof [genInt, genSym, genStr]
genExpr n = frequency
  [ (3, genInt), (3, genSym), (2, genStr)
  , (2, SList <$> resize 4 (listOf (genExpr (n `div` 2)))) ]

genInt :: Gen SExpr
genInt = SInt . toInteger <$> (arbitrary :: Gen Int)

genSym :: Gen SExpr
genSym = do
  c <- elements ['a' .. 'z']
  cs <- listOf (elements (['a' .. 'z'] ++ ['A' .. 'Z'] ++ "-_+*/<>=!?"))
  return (SSym (c : cs))

genStr :: Gen SExpr
genStr = SStr <$> listOf (elements (['a' .. 'z'] ++ " ;()#"))

spec :: Spec
spec = do
  it "parses lists, atoms and strings" $
    parseSExprs "(card X-1 (name \"A b\") 12 -3)" `shouldBe`
      Just [SList [SSym "card", SSym "X-1", SList [SSym "name", SStr "A b"], SInt 12, SInt (-3)]]
  it "skips comments and mixed whitespace" $
    parseSExprs "; hi\n(a\t;x\r\n b)\f\v" `shouldBe` Just [SList [SSym "a", SSym "b"]]
  it "does not treat a semicolon inside a string as a comment" $
    parseSExprs "\"a;b\"" `shouldBe` Just [SStr "a;b"]
  it "treats +5 and 1.5 as symbols" $
    parseSExprs "+5 1.5" `shouldBe` Just [SSym "+5", SSym "1.5"]
  it "accepts the 64-bit extremes and rejects overflow" $ do
    parseSExprs "9223372036854775807" `shouldBe` Just [SInt 9223372036854775807]
    parseSExprs "-9223372036854775808" `shouldBe` Just [SInt (-9223372036854775808)]
    parseSExprs "9223372036854775808" `shouldBe` Nothing
  it "rejects unbalanced parentheses" $ do
    parseSExprs "(a" `shouldBe` Nothing
    parseSExprs "a)" `shouldBe` Nothing
  it "rejects unterminated and multi-line strings" $ do
    parseSExprs "\"abc" `shouldBe` Nothing
    parseSExprs "\"a\nb\"" `shouldBe` Nothing
  it "renders canonically" $
    render (SList [SSym "a", SInt 7, SStr "x y", SList []]) `shouldBe` "(a 7 \"x y\" ())"
  it "round-trips render and parse" $
    property $ forAll (genExpr 4) $ \e -> parseSExprs (render e) === Just [e]
