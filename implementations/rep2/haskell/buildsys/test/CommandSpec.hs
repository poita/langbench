module CommandSpec (spec) where

import qualified Data.ByteString.Char8 as BC
import Test.Hspec

import Kiln.Command
import Kiln.Workspace

-- | Run a command over inputs given as (path, content).
run :: Command -> [(String, String)] -> Either String String
run cmd ins =
  either (Left . show) (Right . BC.unpack . coContent)
    (runCommand cmd [(BC.pack p, mkFile (BC.pack c)) | (p, c) <- ins] emptyWorkspace)

one :: String -> [(String, String)]
one c = [("in.txt", c)]

spec :: Spec
spec = do
  it "write emits its argument" $ run (Command Write [ArgStr "hi\n"]) [] `shouldBe` Right "hi\n"
  it "upper and lower touch only ASCII letters" $ do
    run (Command Upper []) (one "abc\195\188") `shouldBe` Right "ABC\195\188"
    run (Command Lower []) (one "ABC") `shouldBe` Right "abc"
  it "grep keeps matching lines and re-terminates them" $
    run (Command Grep [ArgStr "a"]) (one "a\nb\nab") `shouldBe` Right "a\nab\n"
  it "an empty grep needle matches every line" $
    run (Command Grep [ArgStr ""]) (one "x\ny") `shouldBe` Right "x\ny\n"
  it "replace works on the whole content" $
    run (Command Replace [ArgStr "a\nb", ArgStr "-"]) (one "a\nb\na\nb") `shouldBe` Right "-\n-"
  it "sort_lines, reverse_lines and dedup" $ do
    run (Command SortLines []) (one "b\na\nc\n") `shouldBe` Right "a\nb\nc\n"
    run (Command ReverseLines []) (one "a\nb") `shouldBe` Right "b\na\n"
    run (Command Dedup []) (one "a\nb\na\n") `shouldBe` Right "a\nb\n"
  it "number and indent prefix every line, including empty ones" $ do
    run (Command Number []) (one "a\n\nb\n") `shouldBe` Right "1: a\n2: \n3: b\n"
    run (Command Indent [ArgInt 2]) (one "a\n\n") `shouldBe` Right "  a\n  \n"
  it "wrap does no line processing" $
    run (Command Wrap [ArgStr "<", ArgStr ">"]) (one "x") `shouldBe` Right "<x>"
  it "count_lines lists each input and a total" $
    run (Command CountLines []) [("a", "1\n2\n"), ("b", "")] `shouldBe` Right "2 a\n0 b\n2 total\n"
  it "hash prints FNV-1a hashes" $
    run (Command HashCmd []) [("p", "hello\n")] `shouldBe` Right "a9bc80cca21f28b3 p\n"
  describe "renderCommand" $ do
    it "escapes strings" $
      renderCommand (Command Write [ArgStr "a\"\\\n\t\r\0\DEL\195\188"])
        `shouldBe` "write(\"a\\\"\\\\\\n\\t\\r\\x00\\x7f\195\188\")"
    it "renders ints and empty argument lists" $ do
      renderCommand (Command Indent [ArgInt 4]) `shouldBe` "indent(4)"
      renderCommand (Command Concat []) `shouldBe` "concat()"
  describe "shape and argument checks" $ do
    it "checks input counts, output counts and depfiles in order" $ do
      fmap show (shapeError Write 1 1 False)
        `shouldBe` Just "ECmdShape \"write\" \"expected inputs 0-0, got 1\""
      fmap show (shapeError Concat 0 1 False)
        `shouldBe` Just "ECmdShape \"concat\" \"expected inputs 1-N, got 0\""
      fmap show (shapeError Copy 1 2 False)
        `shouldBe` Just "ECmdShape \"copy\" \"expected outputs 1, got 2\""
      fmap show (shapeError Preprocess 1 1 False)
        `shouldBe` Just "ECmdShape \"preprocess\" \"depfile required\""
      fmap show (shapeError Copy 1 1 True)
        `shouldBe` Just "ECmdShape \"copy\" \"depfile not allowed\""
      shapeError Preprocess 1 1 True `shouldBe` Nothing
    it "rejects an empty replace pattern and a negative indent" $ do
      argError (Command Replace [ArgStr "", ArgStr "x"]) `shouldSatisfy` (/= Nothing)
      argError (Command Indent [ArgInt (-1)]) `shouldSatisfy` (/= Nothing)
  describe "preprocess" $ do
    let pre ins snapshot =
          runCommand (Command Preprocess []) ins (fromFiles [(BC.pack p, BC.pack c) | (p, c) <- snapshot])
        main' = [("m", mkFile "a\n@need p\nz\n")]
    it "expands needs and records the discovered set" $
      case pre main' [("p", "P\n@need q\n"), ("q", "Q\n")] of
        Right o -> do
          coContent o `shouldBe` "a\nP\nQ\nz\n"
          coDiscovered o `shouldBe` ["p", "q"]
          coDepfile o `shouldBe` Just "kiln-deps 1\nneed p\nneed q\n"
        Left e -> expectationFailure (show e)
    it "fails on cycles, missing files and bad paths" $ do
      either show (const "ok") (pre main' [("p", "@need p\n")]) `shouldBe` "ENeedCycle \"p\""
      either show (const "ok") (pre main' []) `shouldBe` "ENeedMissing \"p\" \"m\""
      either show (const "ok") (pre [("m", mkFile "@need ../x\n")] [])
        `shouldBe` "ENeedPath \"../x\""
