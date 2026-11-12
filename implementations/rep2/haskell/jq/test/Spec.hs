module Main (main) where

import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import qualified Data.Sequence as Seq
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Test.Hspec
import Test.QuickCheck

import Jq
import Jq.Json.Encoder (renderValue)
import Jq.Number (formatNumber)

-- | Run a filter on a JSON document given as text; render each output, and
-- append "error" if evaluation aborted (mirrors the CLI contract).
run :: String -> String -> [String]
run f doc = case (parseFilter (T.pack f), parseJSON (utf8 doc)) of
  (Right e, Right v) ->
    let (vs, err) = results e v
    in map (T.unpack . TE.decodeUtf8 . BL.toStrict . renderValue) vs ++ maybe [] (const ["error"]) err
  (Left m, _) -> ["parse error: " ++ m]
  (_, Left m) -> ["json error: " ++ m]

utf8 :: String -> BC.ByteString
utf8 = TE.encodeUtf8 . T.pack

yields :: (String, String) -> [String] -> Expectation
(f, doc) `yields` out = run f doc `shouldBe` out

genValue :: Int -> Gen Value
genValue 0 = oneof [pure VNull, VBool <$> arbitrary, VNum . fromIntegral <$> (arbitrary :: Gen Int), VStr . T.pack <$> arbitrary]
genValue n = frequency
  [ (3, genValue 0)
  , (1, VArr . Seq.fromList <$> resize 4 (listOf (genValue (n `div` 2))))
  , (1, VObj . objectFromList <$> resize 4 (listOf ((,) <$> (T.pack <$> arbitrary) <*> genValue (n `div` 2))))
  ]

main :: IO ()
main = hspec $ do
  describe "JSON round trip" $ do
    it "parses and re-prints compact input unchanged" $
      let doc = "{\"b\":[1,2.5,{\"x\":null}],\"a\":\"h\\u00e9\\n\",\"c\":true}"
      in ("." , doc) `yields` ["{\"b\":[1,2.5,{\"x\":null}],\"a\":\"h\233\\n\",\"c\":true}"]
    it "decodes surrogate pairs" $ (".", "\"\\ud83d\\ude00\"") `yields` ["\"\128512\""]
    it "escapes control characters and DEL" $ (".", "\"\\u0001\\u007f\\/\"") `yields` ["\"\\u0001\\u007f/\""]
    it "prints integers and decimals" $ ("." , "[1000000000000, 0.125, -12, 3086419725308.5]") `yields` ["[1000000000000,0.125,-12,3086419725308.5]"]
    it "rounds numbers correctly" $ (".", "0.1") `yields` ["0.1"]
    it "formats numbers" $ map formatNumber [0.1, 1.5, 1e-7, 123456.789] `shouldBe` ["0.1", "1.5", "1e-07", "123456.789"]
    it "rejects malformed documents" $ parseJSON (utf8 "[1,") `shouldSatisfy` either (const True) (const False)
    it "round-trips arbitrary values" $ forAll (sized (genValue . min 6)) $ \v ->
      fmap (BL.toStrict . renderValue) (parseJSON (BL.toStrict (renderValue v))) == Right (BL.toStrict (renderValue v))

  describe "ordering" $ do
    it "orders types" $ ("sort", "[{},[],\"a\",1,true,false,null]") `yields` ["[null,false,true,1,\"a\",[],{}]"]
    it "orders strings by code point" $ ("sort", "[\"é\",\"z\",\"Z\",\"a\"]") `yields` ["[\"Z\",\"a\",\"z\",\"é\"]"]
    it "compares objects by sorted keys then values" $
      ("sort", "[{\"b\":1},{\"a\":2},{\"a\":1}]") `yields` ["[{\"a\":1},{\"a\":2},{\"b\":1}]"]
    it "is a total preorder (QuickCheck)" $ forAll (sized (genValue . min 4)) $ \a -> forAll (sized (genValue . min 4)) $ \b ->
      compareValues a b == invert (compareValues b a)

  describe "paths" $ do
    it "indexes with negatives" $ (".[-1], .[5]", "[1,2,3]") `yields` ["3", "null"]
    it "slices arrays and strings" $ ("(.a[1:], .a[:-1], .s[1:3])", "{\"a\":[1,2,3],\"s\":\"héllo\"}") `yields` ["[2,3]", "[1,2]", "\"él\""]
    it "iterates objects in insertion order" $ (".[]", "{\"z\":1,\"a\":2}") `yields` ["1", "2"]
    it "generator order for T[K]" $ ("([1,2],[3,4])[(0,1)]", "null") `yields` ["1", "3", "2", "4"]
    it "errors on number index of a string key" $ (".a", "5") `yields` ["error"]

  describe "optional" $ do
    it "tolerates one operation" $ ("[.[] | .a?]", "[{\"a\":1},5]") `yields` ["[1]"]
    it "does not suppress errors in the target" $ (".a.b?", "5") `yields` ["error"]
    it "acts as try after other terms" $ ("[(1,2,error,3)?]", "null") `yields` ["[1,2]"]
    it "does not catch downstream errors" $ ("(1,2)? | error", "null") `yields` ["error"]
    it "skips failed combinations" $ ("[([1],2,[3])[0]?]", "null") `yields` ["[1,3]"]

  describe "arithmetic" $ do
    it "right operand is the outer loop" $ ("[(1,2) + (10,20)]", "null") `yields` ["[11,12,21,22]"]
    it "merges objects keeping positions" $ ("{\"z\":1,\"a\":2} + {\"m\":3,\"z\":9}", "null") `yields` ["{\"z\":9,\"a\":2,\"m\":3}"]
    it "merges objects recursively" $ ("{\"a\":{\"x\":1,\"y\":2}} * {\"a\":{\"x\":9}}", "null") `yields` ["{\"a\":{\"x\":9,\"y\":2}}"]
    it "handles strings" $ ("[\"ab\" * 3, \"ab\" * 0, \"ab\" * -1, \"a,b,,c\" / \",\", \"\" / \",\", \"abc\" / \"\"]", "null")
      `yields` ["[\"ababab\",\"\",null,[\"a\",\"b\",\"\",\"c\"],[],[\"a\",\"b\",\"c\"]]"]
    it "computes C-style remainders" $ ("[-7 % 3, 7 % -3, 5.5 % 2]", "null") `yields` ["[-1,1,1]"]
    it "subtracts arrays" $ ("[1,2,3,2] - [2]", "null") `yields` ["[1,3]"]
    it "rejects division by zero" $ ("1 / 0", "null") `yields` ["error"]

  describe "control flow" $ do
    it "short-circuits and/or" $ ("(false and error), (true or error)", "null") `yields` ["false", "true"]
    it "supports if/elif/else" $ ("[.[] | if . < 0 then \"neg\" elif . == 0 then \"zero\" else \"pos\" end]", "[-1,0,1]") `yields` ["[\"neg\",\"zero\",\"pos\"]"]
    it "binds variables over generators" $ ("(1,2) as $x | $x * 10", "null") `yields` ["10", "20"]
    it "reduces" $ ("reduce .[] as $x (0; . + $x)", "[1,2,3]") `yields` ["6"]
    it "builds objects as a cartesian product" $ ("{a:(1,2), b:(3,4)}", "null")
      `yields` ["{\"a\":1,\"b\":3}", "{\"a\":1,\"b\":4}", "{\"a\":2,\"b\":3}", "{\"a\":2,\"b\":4}"]
    it "prints partial output before an error" $ (".[] | if . == 2 then error else . end", "[1,2,3]") `yields` ["1", "error"]

  describe "builtins" $ do
    it "sorts stably by multiple keys" $ ("sort_by(.a, .b) | map(.i)", "[{\"a\":1,\"b\":2,\"i\":0},{\"a\":1,\"b\":1,\"i\":1},{\"a\":0,\"b\":9,\"i\":2}]") `yields` ["[2,1,0]"]
    it "groups" $ ("group_by(.k) | map(length)", "[{\"k\":\"b\"},{\"k\":\"a\"},{\"k\":\"b\"}]") `yields` ["[1,2]"]
    it "uniques, mins and maxes" $ ("unique, min, max, ([] | min)", "[3,1,3,2]") `yields` ["[1,2,3]", "1", "3", "null"]
    it "adds" $ ("add, ([[1],[2]] | add), ([] | add)", "[1,2,3.5]") `yields` ["6.5", "[1,2]", "null"]
    it "keys and has" $ ("keys, has(\"b\"), has(\"z\")", "{\"b\":1,\"a\":2}") `yields` ["[\"a\",\"b\"]", "true", "false"]
    it "length of various types" $ ("[.[] | length]", "[null,-2.5,\"\\ud83d\\ude00\",[1],{\"a\":1}]") `yields` ["[0,2.5,1,1,1]"]
    it "converts with tostring/tonumber" $ ("[.[] | tostring], [.[] | tonumber?]", "[1.5,\"12\",\"x\"]") `yields` ["[\"1.5\",\"12\",\"x\"]", "[1.5,12]"]
    it "map works on objects" $ ("map(. + 1)", "{\"a\":1,\"b\":2}") `yields` ["[2,3]"]
    it "select with generators" $ ("[.[] | select(. > 1, . < 3)]", "[1,2,3]") `yields` ["[1,2,2,3]"]
    it "error(empty) yields nothing" $ ("[error(empty)]", "null") `yields` ["[]"]

invert :: Ordering -> Ordering
invert LT = GT
invert GT = LT
invert EQ = EQ
