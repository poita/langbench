module SessionSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import Test.Hspec

import Kiln.Session
import qualified Kiln.Workspace as W

-- | Run a session over an in-memory workspace.
session :: [(BS.ByteString, BS.ByteString)] -> BS.ByteString -> IO (W.Workspace, [BS.ByteString])
session files script = do
  (ws, logText) <- runSession (W.fromList files) (parseSession script)
  pure (ws, BC.lines (BL.toStrict logText))

content :: W.Workspace -> BS.ByteString -> Maybe BS.ByteString
content ws p = W.lookupContent p ws

hello :: BS.ByteString
hello = "step {\n    out \"out/hello.txt\"\n    cmd write(\"hello\\n\")\n}\ndefault \"out/hello.txt\"\n"

spec :: Spec
spec = do
  describe "session parsing" $ do
    it "skips blanks and comments, reads -j" $
      parseSession "# c\n\n  build a b -j 4\nclean\n" `shouldBe` [Build ["a", "b"] 4, Clean]
    it "reads -j as a target when it is not second to last" $
      parseSession "build -j\nbuild a -j\n" `shouldBe` [Build ["-j"] 1, Build ["a", "-j"] 1]
    it "keeps content lines verbatim" $
      parseSession "create p\n# not a comment\n  x \n\n---\ntouch p\n"
        `shouldBe` [Create "p" "# not a comment\n  x \n\n", Touch "p"]

  describe "worked examples" $ do
    it "example 1: one step, with its state file" $ do
      (ws, l) <- session [("main.kiln", hello)] "build\n"
      l `shouldBe` ["step 1: build (default) -j 1", "  run 0 1 w0 out/hello.txt write(\"hello\\n\")", "  ok ran=1 hit=0 time=1"]
      content ws "out/hello.txt" `shouldBe` Just "hello\n"
      content ws ".kiln-state"
        `shouldBe` Just "kiln-state 1\nstep out/hello.txt\ncmd write(\"hello\\n\")\nout out/hello.txt a9bc80cca21f28b3\nend\n"
    it "example 2: touch is not a change" $ do
      (_, l) <- session [("main.kiln", hello)] "build\nbuild\ntouch main.kiln\nbuild\n"
      drop 3 l
        `shouldBe` [ "step 2: build (default) -j 1", "  hit 0 out/hello.txt", "  ok ran=0 hit=1 time=0"
                   , "step 3: touch main.kiln", "  ok"
                   , "step 4: build (default) -j 1", "  hit 0 out/hello.txt", "  ok ran=0 hit=1 time=0"
                   ]
    it "example 3: parallel scheduling and tie-breaking" $ do
      let steps =
            BS.concat
              [ "step {\n out \"out/" <> n <> ".txt\"\n cmd write(\"" <> up <> "\\n\")\n cost " <> c <> "\n}\n"
              | (n, up, c) <- [("a", "A", "3"), ("b", "B", "1"), ("c", "C", "4"), ("d", "D", "2")]
              ]
          main' = steps <> "step {\n out \"out/all.txt\"\n in [\"out/a.txt\", \"out/b.txt\", \"out/c.txt\", \"out/d.txt\"]\n cmd concat()\n cost 2\n}\ndefault \"out/all.txt\"\n"
      (ws, l) <- session [("main.kiln", main')] "build -j 2\n"
      l
        `shouldBe` [ "step 1: build (default) -j 2"
                   , "  run 0 3 w0 out/a.txt write(\"A\\n\")"
                   , "  run 0 1 w1 out/b.txt write(\"B\\n\")"
                   , "  run 1 5 w1 out/c.txt write(\"C\\n\")"
                   , "  run 3 5 w0 out/d.txt write(\"D\\n\")"
                   , "  run 5 7 w0 out/all.txt concat()"
                   , "  ok ran=5 hit=0 time=7"
                   ]
      content ws "out/all.txt" `shouldBe` Just "A\nB\nC\nD\n"
    it "example 8: early cutoff" $ do
      let m = "step {\n out \"out/mid.txt\"\n in \"src/a.txt\"\n cmd upper()\n}\nstep {\n out \"out/final.txt\"\n in \"out/mid.txt\"\n cmd number()\n}\ndefault \"out/final.txt\"\n"
      (_, l) <- session [("main.kiln", m), ("src/a.txt", "abc\n")] "build\nedit src/a.txt\nABC\n---\nbuild\n"
      drop 4 l
        `shouldBe` [ "step 2: edit src/a.txt", "  ok size=4"
                   , "step 3: build (default) -j 1"
                   , "  run 0 2 w0 out/mid.txt upper()"
                   , "  hit 2 out/final.txt"
                   , "  ok ran=1 hit=1 time=2"
                   ]
    it "example 9: a cycle is a configuration error that writes nothing" $ do
      let m = "step {\n out \"out/x.txt\"\n in \"out/y.txt\"\n cmd copy()\n}\nstep {\n out \"out/y.txt\"\n in \"out/x.txt\"\n cmd copy()\n}\ndefault \"out/x.txt\"\n"
      (ws, l) <- session [("main.kiln", m)] "build\n"
      l `shouldBe` ["step 1: build (default) -j 1", "  error E_CYCLE out/x.txt -> out/y.txt -> out/x.txt"]
      map fst (W.toList ws) `shouldBe` ["main.kiln"]
    it "example 11: clean" $ do
      (_, l) <- session [("main.kiln", hello)] "build\nclean\nbuild\n"
      drop 3 l
        `shouldBe` [ "step 2: clean", "  remove .kiln-state", "  remove out/hello.txt", "  ok removed=2"
                   , "step 3: build (default) -j 1", "  run 0 1 w0 out/hello.txt write(\"hello\\n\")", "  ok ran=1 hit=0 time=1"
                   ]
    it "example 12: an execution error cancels work in flight" $ do
      let m = "step {\n out \"out/doc.txt\"\n depfile \"out/doc.d\"\n in \"src/main.txt\"\n cmd preprocess()\n}\nstep {\n out \"out/slow.txt\"\n cmd write(\"slow\\n\")\n cost 10\n}\nstep {\n out \"out/after.txt\"\n in \"out/doc.txt\"\n cmd copy()\n}\nphony all = [\"out/doc.txt\", \"out/slow.txt\", \"out/after.txt\"]\ndefault \"@all\"\n"
      (ws, l) <- session [("main.kiln", m), ("src/main.txt", "@need src/gone.txt\n")] "build -j 2\n"
      l
        `shouldBe` [ "step 1: build (default) -j 2"
                   , "  fail 0 6 w0 out/doc.txt preprocess()"
                   , "  cancel 0 10 w1 out/slow.txt write(\"slow\\n\")"
                   , "  error E_NEED_MISSING src/gone.txt needed by src/main.txt"
                   ]
      content ws ".kiln-state" `shouldBe` Just "kiln-state 1\n"
      content ws "out/slow.txt" `shouldBe` Nothing
    it "example 15: tampering with an output rebuilds it" $ do
      (_, l) <- session [("main.kiln", hello)] "build\nedit out/hello.txt\ntampered\n---\nbuild\n"
      drop 5 l `shouldBe` ["step 3: build (default) -j 1", "  run 0 1 w0 out/hello.txt write(\"hello\\n\")", "  ok ran=1 hit=0 time=1"]

  describe "configuration errors" $ do
    let err m expected = do
          (_, l) <- session [("main.kiln", m)] "build\n"
          drop 1 l `shouldBe` ["  error " <> expected]
    it "E_NO_DEFAULT" $ err "step {\n out \"out/z.txt\"\n cmd write(\"ok\")\n}\n" "E_NO_DEFAULT"
    it "E_ABORT" $ err "let n = 3\nwhen n > 2 {\n abort \"n too large: {n}\"\n}\n" "E_ABORT n too large: 3"
    it "E_DUP_OUTPUT" $
      err "step {\n out \"out/z\"\n cmd write(\"1\")\n}\nstep {\n out \"out/z\"\n cmd write(\"2\")\n}\ndefault \"out/z\"\n" "E_DUP_OUTPUT out/z"
    it "E_MISSING_INPUT" $
      err "step {\n out \"out/z\"\n in \"src/none\"\n cmd copy()\n}\ndefault \"out/z\"\n" "E_MISSING_INPUT src/none required by out/z"
    it "E_PARSE" $ err "let a = 1\nlet = 2\n" "E_PARSE main.kiln:2"
    it "E_REDEFINE" $ err "let a = 1\nlet a = 2\n" "E_REDEFINE a"
    it "E_RULE_RECURSION" $ err "rule r() {\n use r()\n}\nuse r()\n" "E_RULE_RECURSION r"
    it "E_OUTPUT_PATH" $ err "step {\n out \"x.txt\"\n cmd write(\"\")\n}\n" "E_OUTPUT_PATH x.txt"
    it "E_CMD_SHAPE" $
      err "step {\n out \"out/z\"\n cmd copy()\n}\n" "E_CMD_SHAPE copy: expected inputs 1-1, got 0"
    it "reports a missing build file" $ do
      (_, l) <- session [] "build\n"
      l `shouldBe` ["step 1: build (default) -j 1", "  error E_NO_BUILD_FILE main.kiln"]
