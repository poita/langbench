module EvalSpec (spec) where

import Test.Hspec

import Support

-- | Expect the expression to evaluate to the given text.
(==>) :: String -> String -> Expectation
e ==> v = evalExpr e `shouldBe` Right v

-- | Expect the expression to fail with the given error.
(!=>) :: String -> String -> Expectation
e !=> err = evalExpr e `shouldBe` Left err

spec :: Spec
spec = do
  describe "operators" $ do
    it "does integer arithmetic truncating toward zero" $ do
      "\"{7 / 2} {-7 / 2} {-7 % 3} {7 % -3}\"" ==> "3 -3 -1 1"
    it "reports division by zero" $ "\"{1 / 0}\"" !=> "E_DIV_ZERO"
    it "type-checks the left operand first" $
      "\"{\"a\" + [1]}\"" !=> "E_TYPE operator +: expected int, got str"
    it "short-circuits || and &&" $ do
      "\"{true || nope}\"" ==> "true"
      "\"{false && nope}\"" ==> "false"
      "\"{false || nope}\"" !=> "E_UNKNOWN_VAR nope"
    it "orders values bool < int < str < list" $
      "\"{true < 0} {1 < \"a\"} {\"a\" < []} {[1, 2] < [1, 3]} {[1] < [1, 0]}\""
        ==> "true true true true true"
    it "compares structurally" $ "\"{[1, [2]] == [1, [2]]} {1 == \"1\"}\"" ==> "true false"
  describe "strings" $ do
    it "interpolates ints and bools but not lists" $ do
      "\"a{1 + 1}b{true}\"" ==> "a2btrue"
      "\"{[1]}\"" !=> "E_INTERP list"
    it "supports doubled braces and single-quoted literals" $ do
      "\"{{x}}\"" ==> "{x}"
      "'a\\n{x}'" ==> "a\\n{x}"
    it "indexes bytes, counting negatives from the end" $ do
      "\"abc\"[-1]" ==> "c"
      "\"abc\"[3]" !=> "E_ARG fn index: out of range"
      "5[\"a\"]" !=> "E_TYPE index: expected int, got str"
  describe "built-in functions" $ do
    it "substr clamps" $ do
      "substr(\"abcdef\", -2, 5)" ==> "ef"
      "substr(\"abcdef\", 2, -1)" ==> ""
    it "split keeps empty pieces" $ "join(split(\"a,,b\", \",\"), \"|\")" ==> "a||b"
    it "stem and ext ignore a leading dot" $ do
      "stem(\"src/.hidden\") ~ \"/\" ~ ext(\"src/.hidden\")" ==> ".hidden/"
      "stem(\"a.b.txt\") ~ ext(\"a.b.txt\")" ==> "a.b.txt"
    it "map substitutes % and %%" $ "join(map([\"a\"], \"100%%-%\"), \",\")" ==> "100%-a"
    it "sort uses the total order and uniq keeps first occurrences" $ do
      "join(sort([\"b\", \"a\"]), \"\")" ==> "ab"
      "join(uniq([1, 2, 1, 3]), \",\")" ==> "1,2,3"
    it "pipes desugar to calls" $ "\"abc\" |> upper |> substr(1, 1)" ==> "B"
    it "arity is checked after the arguments are evaluated" $ do
      "upper(undefined, 2)" !=> "E_UNKNOWN_VAR undefined"
      "upper(\"a\", 2)" !=> "E_ARITY fn upper: expected 1, got 2"
      "pathjoin()" !=> "E_ARITY fn pathjoin: expected 1-8, got 0"
    it "reports unknown functions before evaluating arguments" $
      "nope(undefined)" !=> "E_UNKNOWN_FUNC nope"
    it "reports argument types" $
      "upper(1)" !=> "E_TYPE fn upper argument 1: expected str, got int"
    it "int parses decimal strings" $ do
      "str(int(\"-12\") + 1)" ==> "-11"
      "int(\"+1\")" !=> "E_ARG fn int: bad integer"
      "int(\"9223372036854775808\")" !=> "E_ARG fn int: bad integer"
    it "filter compiles its pattern before looking at elements" $
      "filter([1], \"\")" !=> "E_ARG fn filter: bad pattern"
    it "pathjoin drops empty arguments" $ "pathjoin(\"out\", \"\", \"a.txt\")" ==> "out/a.txt"
    it "zip truncates to the shorter list" $ "str(count(zip([1, 2, 3], [4])))" ==> "1"
