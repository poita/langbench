{-# LANGUAGE ScopedTypeVariables #-}
module Main (main) where

import qualified Data.ByteString.Char8 as B8
import Data.List (sort)
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as T
import Jq
import Test.Hspec
import Test.QuickCheck

-- | Run a filter on a document and render every output, with a final
-- @error@ line if evaluation failed (the CLI contract).
run :: Text -> Text -> [Text]
run f doc = case query f doc of
  Left e -> [T.pack ("PARSE ERROR: " ++ e)]
  Right outs -> map (either (const "error") renderText) outs

shouldGive :: (Text, Text) -> [Text] -> Expectation
shouldGive (f, doc) expected = run f doc `shouldBe` expected

main :: IO ()
main = hspec $ do
  describe "JSON parser" $ do
    it "parses scalars" $ do
      parseJson (B8.pack " null ") `shouldBe` Right VNull
      parseJson (B8.pack "true") `shouldBe` Right (VBool True)
      parseJson (B8.pack "-12.5") `shouldBe` Right (VNumber (-12.5))
    it "rounds numbers correctly" $
      parseJson (B8.pack "0.1") `shouldBe` Right (VNumber 0.1)
    it "decodes escapes and surrogate pairs" $
      parseJson (B8.pack "\"a\\n\\u00e9\\ud83d\\ude00\"")
        `shouldBe` Right (VString (T.pack "a\n\233\128512"))
    it "keeps object key order" $
      fmap renderText (parseJson (B8.pack "{\"z\":1,\"a\":2}")) `shouldBe` Right (T.pack "{\"z\":1,\"a\":2}")
    it "rejects trailing garbage" $
      parseJson (B8.pack "1 2") `shouldSatisfy` either (const True) (const False)

  describe "serialiser" $ do
    it "escapes control characters and DEL" $
      renderText (VString (T.pack "\1\DEL\"\\/")) `shouldBe` T.pack "\"\\u0001\\u007f\\\"\\\\/\""
    it "prints integers and decimals" $ do
      renderText (VNumber 3) `shouldBe` T.pack "3"
      renderText (VNumber 3086419725308.5) `shouldBe` T.pack "3086419725308.5"
      renderText (VNumber 0.125) `shouldBe` T.pack "0.125"
      renderText (VNumber 1e15) `shouldBe` T.pack "1000000000000000"

  describe "paths" $ do
    it "indexes and iterates" $ do
      (".a[1], .a[-1], .a[5], .b.c", "{\"a\":[1,2,3]}") `shouldGive` ["2", "3", "null", "null"]
      (".[]", "{\"b\":1,\"a\":2}") `shouldGive` ["1", "2"]
    it "slices arrays and strings by code point" $ do
      (".[1:], .[:-1], .[5:]", "[1,2,3]") `shouldGive` ["[2,3]", "[1,2]", "[]"]
      (".[1:3]", "\"h\\u00e9llo\"") `shouldGive` ["\"\233l\""]
    it "orders generators by key then target" $
      ("([1,2],[3,4])[(0,1)]", "null") `shouldGive` ["1", "3", "2", "4"]
    it "errors on bad types" $
      (".a", "5") `shouldGive` ["error"]

  describe "optional" $ do
    it "tolerates one operation" $ do
      (".a?", "5") `shouldGive` []
      ("[(1,[2],3)[]?]", "null") `shouldGive` ["[2]"]
      ("[([1],2,[3])[0]?]", "null") `shouldGive` ["[1,3]"]
    it "does not hide errors in the target" $
      (".a.b?", "5") `shouldGive` ["error"]
    it "acts as try after other terms" $ do
      ("[(1,2,error,3)?]", "null") `shouldGive` ["[1,2]"]
      ("(1,2)? | error", "null") `shouldGive` ["error"]
      ("[.[] | tonumber?]", "[\"1\",\"x\",2]") `shouldGive` ["[1,2]"]

  describe "operators" $ do
    it "evaluates the right operand as the outer loop" $
      ("[(1,2) + (10,20)]", "null") `shouldGive` ["[11,12,21,22]"]
    it "does arithmetic on mixed types" $ do
      ("(\"ab\" * 3), (\"ab\" * 0), (\"ab\" * -1), (\"a,b,,c\" / \",\")", "null")
        `shouldGive` ["\"ababab\"", "\"\"", "null", "[\"a\",\"b\",\"\",\"c\"]"]
      ("-7 % 3, 7 % -3, 5.5 % 2", "null") `shouldGive` ["-1", "1", "1"]
      ("[1,2,3,2] - [2]", "null") `shouldGive` ["[1,3]"]
      ("1 / 0", "null") `shouldGive` ["error"]
    it "merges objects keeping first positions" $ do
      ("{\"z\":1,\"a\":2} + {\"m\":3,\"z\":9}", "null") `shouldGive` ["{\"z\":9,\"a\":2,\"m\":3}"]
      ("{a:{x:1,y:2}} * {a:{x:9}}", "null") `shouldGive` ["{\"a\":{\"x\":9,\"y\":2}}"]
    it "short-circuits and/or" $ do
      ("false and error, true or error", "null") `shouldGive` ["false", "true"]
    it "orders values" $
      ("[[1],{},\"a\",1,true,false,null] | sort", "null")
        `shouldGive` ["[null,false,true,1,\"a\",[1],{}]"]

  describe "constructs" $ do
    it "builds objects with generator order" $
      ("{a:(1,2), b:(3,4)}", "null")
        `shouldGive` ["{\"a\":1,\"b\":3}", "{\"a\":1,\"b\":4}", "{\"a\":2,\"b\":3}", "{\"a\":2,\"b\":4}"]
    it "supports shorthand entries and computed keys" $
      ("5 as $x | {a, \"b\", $x, (\"k\" + \"1\"): 1}", "{\"a\":1,\"b\":2}")
        `shouldGive` ["{\"a\":1,\"b\":2,\"x\":5,\"k1\":1}"]
    it "binds variables and reduces" $ do
      (".[] as $x | $x * 2", "[1,2]") `shouldGive` ["2", "4"]
      ("reduce .[] as $x (0; . + $x)", "[1,2,3]") `shouldGive` ["6"]
      ("reduce .[] as $x (0; empty)", "[1,2,3]") `shouldGive` ["null"]
    it "handles if/elif/else" $
      ("if . < 0 then \"neg\" elif . == 0 then \"zero\" else \"pos\" end", "0") `shouldGive` ["\"zero\""]

  describe "builtins" $ do
    it "sorts stably by multiple keys" $
      ("sort_by(.k, -.v)", "[{\"k\":\"b\",\"v\":1},{\"k\":\"a\",\"v\":2},{\"k\":\"b\",\"v\":3}]")
        `shouldGive` ["[{\"k\":\"a\",\"v\":2},{\"k\":\"b\",\"v\":3},{\"k\":\"b\",\"v\":1}]"]
    it "groups, uniques, mins and maxes" $ do
      ("group_by(. % 2)", "[1,2,3,4]") `shouldGive` ["[[2,4],[1,3]]"]
      ("unique", "[3,1,3,2]") `shouldGive` ["[1,2,3]"]
      ("min, max", "[]") `shouldGive` ["null", "null"]
    it "computes length, keys, has, add, type" $ do
      ("length", "\"h\\u00e9\"") `shouldGive` ["2"]
      ("keys", "{\"b\":1,\"a\":2}") `shouldGive` ["[\"a\",\"b\"]"]
      ("has(\"a\"), has(\"c\")", "{\"a\":1}") `shouldGive` ["true", "false"]
      ("add", "[\"a\",\"b\"]") `shouldGive` ["\"ab\""]
      ("add", "[]") `shouldGive` ["null"]
      ("type", "[]") `shouldGive` ["\"array\""]
    it "converts with tostring/tonumber" $ do
      ("tostring", "[1,\"a\"]") `shouldGive` ["\"[1,\\\"a\\\"]\""]
      ("tonumber", "\"-2.5\"") `shouldGive` ["-2.5"]
      ("tonumber", "\"abc\"") `shouldGive` ["error"]
    it "implements error(f)" $ do
      ("error(null)", "1") `shouldGive` ["error"]
      ("error(empty), 1", "1") `shouldGive` ["1"]

  describe "CLI contract" $
    it "prints results before an error, then stops" $
      ("[(1,2) + (10,20)], {a:(1,2), b:(3,4)}, [.[] | .a?], (.[] | .a.b?)", "[{\"a\":{\"b\":1}},{\"a\":5},3]")
        `shouldGive`
          [ "[11,12,21,22]", "{\"a\":1,\"b\":3}", "{\"a\":1,\"b\":4}"
          , "{\"a\":2,\"b\":3}", "{\"a\":2,\"b\":4}", "[{\"b\":1},5]", "1", "error" ]

  describe "properties" $ do
    it "render/parse round-trips" $ property $ \v ->
      parseJson (renderStrict (unGen v)) === Right (unGen v)
    it "sort agrees with Haskell's sort on numbers" $ property $ \(xs :: [Int]) ->
      let doc = T.pack (show xs)
       in run "sort" doc === [T.pack (filter (/= ' ') (show (sort xs)))]
    it "ordering is antisymmetric and consistent with equality" $ property $ \a b ->
      let x = unGen a; y = unGen b
       in compare x y === compare EQ (compare y x) .&&. (x == y) === (compare x y == EQ)
    it "reverse is an involution" $ property $ \(xs :: [Int]) ->
      run "reverse | reverse" (T.pack (show xs)) === [T.pack (filter (/= ' ') (show xs))]
    it "object + preserves first positions" $ property $ \(ks :: [Int]) ->
      let keys = map (T.pack . show . (`mod` 7)) ks
          o = objFromList [(k, VNumber 0) | k <- keys]
       in map fst (objToList o) === dedupe keys

dedupe :: Eq a => [a] -> [a]
dedupe = foldr (\x r -> x : filter (/= x) r) []

-- | Wrapper so QuickCheck can generate JSON values (depth-bounded).
newtype GenValue = GenValue {unGen :: Value}

instance Show GenValue where
  show = show . unGen

instance Arbitrary GenValue where
  arbitrary = GenValue <$> sized (go . min 3)
    where
      go :: Int -> Gen Value
      go 0 = scalar
      go n = oneof
        [ scalar
        , VArray . Seq.fromList <$> small (go (n - 1))
        , VObject . objFromList <$> small ((,) <$> key <*> go (n - 1))
        ]
      scalar = oneof
        [ pure VNull
        , VBool <$> arbitrary
        , VNumber . fromIntegral <$> (arbitrary :: Gen Int)
        , VNumber . (/ 8) . fromIntegral <$> (arbitrary :: Gen Int)
        , VString <$> key
        ]
      small g = choose (0, 3) >>= \k -> vectorOf k g
      key = T.pack <$> small (elements ("ab\"\\\n\233 /z" :: String))
