module CommandSpec (spec) where

import qualified Data.ByteString as BS
import Test.Hspec
import Test.QuickCheck

import Kiln.Command
import Kiln.Error
import Kiln.Hash
import qualified Kiln.Workspace as W

run :: [(BS.ByteString, BS.ByteString)] -> Command -> [BS.ByteString] -> [BS.ByteString] -> Either KilnError [(BS.ByteString, BS.ByteString)]
run files cmd ins outs = resultFiles <$> runCommand (W.fromList files) cmd ins outs

out1 :: [(BS.ByteString, BS.ByteString)] -> Command -> [BS.ByteString] -> Either KilnError BS.ByteString
out1 files cmd ins = fmap (snd . head') (run files cmd ins ["out/x"])
  where
    head' (x : _) = x
    head' [] = ("", "")

spec :: Spec
spec = do
  describe "FNV-1a" $ do
    it "hashes the empty string" $ hashHex (fnv1a64 "") `shouldBe` "cbf29ce484222325"
    it "hashes hello" $ hashHex (fnv1a64 "hello\n") `shouldBe` "a9bc80cca21f28b3"
    it "hashes abc" $ hashHex (fnv1a64 "abc\n") `shouldBe` "fc17b183ee074373"
    it "round-trips through hex" $
      property $ \w -> parseHashHex (hashHex w) === Just w

  describe "lines" $ do
    it "splits per the specification" $ do
      linesOf "a\nb\n" `shouldBe` ["a", "b"]
      linesOf "a\nb" `shouldBe` ["a", "b"]
      linesOf "a\n\nb\n" `shouldBe` ["a", "", "b"]
      linesOf "\n" `shouldBe` [""]
      linesOf "" `shouldBe` []

  describe "canonical command strings" $ do
    it "escapes strings" $
      renderCommand (Command CmdWrite [CStr "a\\b\"\n\t\r\1\DEL\200"]) `shouldBe` "write(\"a\\\\b\\\"\\n\\t\\r\\x01\\x7f\200\")"
    it "renders ints and several arguments" $ do
      renderCommand (Command CmdIndent [CInt 4]) `shouldBe` "indent(4)"
      renderCommand (Command CmdWrap [CStr "<<", CStr ">>"]) `shouldBe` "wrap(\"<<\", \">>\")"
      renderCommand (Command CmdConcat []) `shouldBe` "concat()"

  describe "commands" $ do
    let f = [("a", "b\na\nb\n"), ("c", "x")]
    it "write" $ out1 [] (Command CmdWrite [CStr "hi"]) [] `shouldBe` Right "hi"
    it "grep with an empty needle re-emits lines" $
      out1 f (Command CmdGrep [CStr ""]) ["a"] `shouldBe` Right "b\na\nb\n"
    it "grep" $ out1 f (Command CmdGrep [CStr "a"]) ["a"] `shouldBe` Right "a\n"
    it "sort_lines" $ out1 f (Command CmdSortLines []) ["a"] `shouldBe` Right "a\nb\nb\n"
    it "dedup" $ out1 f (Command CmdDedup []) ["a"] `shouldBe` Right "b\na\n"
    it "number" $ out1 f (Command CmdNumber []) ["a"] `shouldBe` Right "1: b\n2: a\n3: b\n"
    it "indent indents empty lines too" $
      out1 [("e", "\n")] (Command CmdIndent [CInt 2]) ["e"] `shouldBe` Right "  \n"
    it "wrap does not add newlines" $ out1 f (Command CmdWrap [CStr "<", CStr ">"]) ["c"] `shouldBe` Right "<x>"
    it "replace works on whole content" $
      out1 [("r", "aXa\nXa")] (Command CmdReplace [CStr "Xa", CStr "-"]) ["r"] `shouldBe` Right "a-\n-"
    it "upper leaves non-ASCII bytes alone" $
      out1 [("u", "a\200z")] (Command CmdUpper []) ["u"] `shouldBe` Right "A\200Z"
    it "count_lines totals" $
      out1 [("p", "1\n2\n"), ("q", "")] (Command CmdCountLines []) ["p", "q"] `shouldBe` Right "2 p\n0 q\n2 total\n"
    it "hash lists each input, duplicates included" $
      out1 [("h", "hello\n")] (Command CmdHash []) ["h", "h"]
        `shouldBe` Right "a9bc80cca21f28b3 h\na9bc80cca21f28b3 h\n"

  describe "preprocess" $ do
    let pre files = run files (Command CmdPreprocess []) ["m"] ["out/x", "out/x.d"]
    it "expands needs depth first and writes the depfile" $
      pre [("m", "t\n@need p\ne\n"), ("p", "P\n@need d\n"), ("d", "D\n")]
        `shouldBe` Right [("out/x", "t\nP\nD\ne\n"), ("out/x.d", "kiln-deps 1\nneed d\nneed p\n")]
    it "treats '@need ' with nothing after it as plain text" $
      pre [("m", "@need \n")] `shouldBe` Right [("out/x", "@need \n"), ("out/x.d", "kiln-deps 1\n")]
    it "reports a bad path" $ pre [("m", "@need ../x\n")] `shouldBe` Left (ENeedPath "../x")
    it "reports a missing file" $ pre [("m", "@need g\n")] `shouldBe` Left (ENeedMissing "g" "m")
    it "reports a cycle" $ pre [("m", "@need p\n"), ("p", "@need m\n")] `shouldBe` Left (ENeedCycle "m")
    it "allows a file needed twice without nesting" $
      pre [("m", "@need p\n@need p\n"), ("p", "P\n")]
        `shouldBe` Right [("out/x", "P\nP\n"), ("out/x.d", "kiln-deps 1\nneed p\n")]
