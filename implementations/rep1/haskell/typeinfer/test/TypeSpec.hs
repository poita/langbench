module TypeSpec (spec) where

import Test.Hspec
import Test.QuickCheck

import Language.TypeInfer

a, b, c :: Type
a = TVar 0
b = TVar 1
c = TVar 2

spec :: Spec
spec = describe "renderType" $ do
  it "names variables a..z then a1.." $ do
    map varName [0, 1, 25, 26, 27, 52] `shouldBe` ["'a", "'b", "'z", "'a1", "'b1", "'a2"]
  it "prints base types" $
    map renderType [TInt, TBool, TUnit] `shouldBe` ["int", "bool", "unit"]
  it "treats -> as right associative" $
    renderType (TFun a (TFun b c)) `shouldBe` "'a -> 'b -> 'c"
  it "parenthesises a function on the left of an arrow" $
    renderType (TFun (TFun a b) c) `shouldBe` "('a -> 'b) -> 'c"
  it "does not parenthesise tuples next to arrows" $ do
    renderType (TFun (TTuple [a, b]) a) `shouldBe` "'a * 'b -> 'a"
    renderType (TFun TInt (TTuple [TInt, TInt])) `shouldBe` "int -> int * int"
  it "parenthesises function and tuple components" $
    renderType (TTuple [TFun TInt TInt, TTuple [TInt, TInt], TInt])
      `shouldBe` "(int -> int) * (int * int) * int"
  it "prints list postfix and parenthesises complex elements" $ do
    renderType (TList (TList TInt)) `shouldBe` "int list list"
    renderType (TList (TFun a a)) `shouldBe` "('a -> 'a) list"
    renderType (TList (TTuple [TInt, TBool])) `shouldBe` "(int * bool) list"
    renderType (TTuple [TList TInt, TInt]) `shouldBe` "int list * int"
  it "reports free variables in order of appearance" $
    freeVars (TFun (TFun b a) (TList b)) `shouldBe` [1, 0]
  it "gives distinct names to distinct variables" $
    property $ \(NonNegative i) (NonNegative j) -> (i < (5000 :: Int) && j < 5000 && i /= j)
      ==> varName i /= varName j
