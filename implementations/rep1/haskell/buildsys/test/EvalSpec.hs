module EvalSpec (spec) where

import qualified Data.ByteString as BS
import Test.Hspec

import Kiln.Error
import Kiln.Eval (evalExprText)
import qualified Kiln.Workspace as W

-- | Evaluate an expression and render the result (or the error line).
ev :: BS.ByteString -> IO BS.ByteString
ev src = do
  r <- evalExprText ws src
  pure $ case r of
    Left e -> "error " <> renderError e
    Right v -> BS.concat ["ok ", renderValue v]
  where
    ws = W.fromList [("src/a.txt", ""), ("src/b.txt", ""), ("src/sub/c.txt", ""), ("src/notes.md", ""), ("out/x.txt", ""), (".kiln-state", ""), ("main.kiln", "")]
    renderValue v = BS.concat ["<", showV v, ">"]
    showV = fromString' . show

fromString' :: String -> BS.ByteString
fromString' = BS.pack . map (fromIntegral . fromEnum)

shows' :: BS.ByteString -> BS.ByteString -> Expectation
shows' src expected = ev src >>= (`shouldBe` expected)

okStr :: BS.ByteString -> BS.ByteString
okStr s = "ok <VStr " <> fromString' (show s) <> ">"

okInt :: Int -> BS.ByteString
okInt n = "ok <VInt " <> fromString' (showsPrec 11 n "") <> ">"

spec :: Spec
spec = do
  describe "arithmetic and operators" $ do
    it "divides truncating toward zero" $ shows' "-7 / 2" (okInt (-3))
    it "takes the remainder with the sign of the dividend" $ shows' "-7 % 2" (okInt (-1))
    it "reports division by zero" $ shows' "1 / 0" "error E_DIV_ZERO"
    it "checks the left operand first" $
      shows' "\"a\" + [1]" "error E_TYPE operator +: expected int, got str"
    it "short-circuits ||" $ shows' "true || (1 / 0 == 1)" "ok <VBool True>"
    it "short-circuits &&" $ shows' "false && undefined" "ok <VBool False>"
    it "orders values across types" $ shows' "[true < 0, 0 < \"a\", \"a\" < []]" "ok <VList (fromList [VBool True,VBool True,VBool True])>"
    it "compares lists element-wise" $ shows' "[1, 2] < [1, 3]" "ok <VBool True>"
    it "concatenates strings with ~" $ shows' "\"a\" ~ \"b\"" (okStr "ab")
    it "reports an unknown variable" $ shows' "x + 1" "error E_UNKNOWN_VAR x"
    it "indexes from the end" $ shows' "\"abc\"[-1]" (okStr "c")
    it "reports an index out of range" $ shows' "[1][1]" "error E_ARG fn index: out of range"
    it "checks the index before the target" $
      shows' "5[\"a\"]" "error E_TYPE index: expected int, got str"

  describe "interpolation" $ do
    it "renders ints, bools and strings" $ shows' "\"{1 + 2}-{true}-{\"s\"}\"" (okStr "3-true-s")
    it "rejects lists" $ shows' "\"{[1]}\"" "error E_INTERP list"
    it "allows nested literals containing braces" $ shows' "\"{join([\"a\", \"b\"], \"{{\")}\"" (okStr "a{b")

  describe "built-in functions" $ do
    it "reports unknown functions before evaluating arguments" $
      shows' "nope(undefined)" "error E_UNKNOWN_FUNC nope"
    it "evaluates arguments before the arity check" $
      shows' "upper(undefined, 2)" "error E_UNKNOWN_VAR undefined"
    it "reports arity" $ shows' "upper(\"a\", \"b\")" "error E_ARITY fn upper: expected 1, got 2"
    it "reports a pathjoin range" $ shows' "pathjoin()" "error E_ARITY fn pathjoin: expected 1-8, got 0"
    it "reports argument types" $ shows' "upper(1)" "error E_TYPE fn upper argument 1: expected str, got int"
    it "substr clamps" $ do
      shows' "substr(\"abcdef\", 1, 3)" (okStr "bcd")
      shows' "substr(\"abcdef\", -2, 5)" (okStr "ef")
      shows' "substr(\"abcdef\", 10, 2)" (okStr "")
      shows' "substr(\"abcdef\", 2, -1)" (okStr "")
    it "splits" $ do
      shows' "split(\"\", \",\") |> len" (okInt 1)
      shows' "split(\"a,,b\", \",\") |> join(\"|\")" (okStr "a||b")
      shows' "split(\"a\", \"\")" "error E_ARG fn split: empty separator"
    it "replaces left to right" $ shows' "replace(\"aaa\", \"aa\", \"b\")" (okStr "ba")
    it "stem and ext" $ do
      shows' "stem(\"src/a.b.txt\")" (okStr "a.b")
      shows' "ext(\"src/a.b.txt\")" (okStr ".txt")
      shows' "stem(\"src/.hidden\")" (okStr ".hidden")
      shows' "ext(\"src/x.\")" (okStr ".")
    it "pathjoin drops empty arguments" $ shows' "pathjoin(\"out\", \"\", \"a.txt\")" (okStr "out/a.txt")
    it "map expands % and %%" $ shows' "map([\"a\"], \"100%%-%\") |> first" (okStr "100%-a")
    it "int parses and rejects" $ do
      shows' "int(\"-007\")" (okInt (-7))
      shows' "int(\"+7\")" "error E_ARG fn int: bad integer"
      shows' "int(\"9223372036854775808\")" "error E_ARG fn int: bad integer"
    it "join reports 0-based element types" $
      shows' "join([\"a\", [1]], \",\")" "error E_TYPE fn join element 1: expected str|int, got list"
    it "filter compiles its pattern first" $
      shows' "filter([1], \"\")" "error E_ARG fn filter: bad pattern"
    it "filter reports element types" $
      shows' "filter([\"a\", 1], \"*\")" "error E_TYPE fn filter element 1: expected str, got int"
    it "sorts, dedups and reverses" $ do
      shows' "sort([3, 1, 2]) |> join(\",\")" (okStr "1,2,3")
      shows' "uniq([1, 2, 1, 3, 2]) |> join(\",\")" (okStr "1,2,3")
      shows' "reverse([1, 2]) |> first" (okInt 2)
    it "first of an empty list fails" $ shows' "first([])" "error E_ARG fn first: empty list"
    it "range" $ do
      shows' "range(3) |> sum" (okInt 3)
      shows' "range(-1)" "error E_ARG fn range: negative"
    it "zip truncates" $ shows' "zip([1, 2, 3], [4, 5]) |> len" (okInt 2)
    it "flatten splices one level" $ shows' "flatten([1, [2, [3]]]) |> len" (okInt 3)
    it "indexof uses deep equality" $ shows' "indexof([[1], [2]], [2])" (okInt 1)
    it "glob skips generated paths and the state file" $
      shows' "glob(\"**\") |> join(\" \")" (okStr "main.kiln src/a.txt src/b.txt src/notes.md src/sub/c.txt")
    it "glob narrows by prefix" $ shows' "glob(\"src/*.txt\") |> join(\" \")" (okStr "src/a.txt src/b.txt")
    it "glob rejects malformed patterns" $ shows' "glob(\"[\")" "error E_ARG fn glob: bad pattern"
