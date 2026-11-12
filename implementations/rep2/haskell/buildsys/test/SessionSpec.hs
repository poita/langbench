module SessionSpec (spec) where

import qualified Data.ByteString.Char8 as BC
import Test.Hspec

import Kiln
import Support

hello :: (String, String)
hello = ("main.kiln", "step {\n out \"out/hello.txt\"\n cmd write(\"hello\\n\")\n}\ndefault \"out/hello.txt\"\n")

spec :: Spec
spec = do
  describe "parseSession" $ do
    it "skips blanks and comments and parses -j" $
      parseSession "# c\n\nbuild @all -j 4\nbuild a b\nbuild -j\nclean\n"
        `shouldBe` [SBuild ["@all"] 4, SBuild ["a", "b"] 1, SBuild ["-j"] 1, SClean]
    it "keeps content lines verbatim until ---" $
      parseSession "create p\n  a \n\n# not a comment\n---\ndelete p\n"
        `shouldBe` [SCreate "p" "  a \n\n# not a comment\n", SDelete "p"]
  describe "runSession" $ do
    it "caches, ignores touch and detects tampered outputs (examples 2 and 15)" $
      runLog [hello] "build\ntouch main.kiln\nbuild\nedit out/hello.txt\nx\n---\nbuild\n"
        `shouldBe` [ "step 1: build (default) -j 1"
                   , "  run 0 1 w0 out/hello.txt write(\"hello\\n\")"
                   , "  ok ran=1 hit=0 time=1"
                   , "step 2: touch main.kiln"
                   , "  ok"
                   , "step 3: build (default) -j 1"
                   , "  hit 0 out/hello.txt"
                   , "  ok ran=0 hit=1 time=0"
                   , "step 4: edit out/hello.txt"
                   , "  ok size=2"
                   , "step 5: build (default) -j 1"
                   , "  run 0 1 w0 out/hello.txt write(\"hello\\n\")"
                   , "  ok ran=1 hit=0 time=1"
                   ]
    it "cleans generated paths and the state file (example 11)" $
      drop 3 (runLog [hello] "build\nclean\n")
        `shouldBe` [ "step 2: clean"
                   , "  remove .kiln-state"
                   , "  remove out/hello.txt"
                   , "  ok removed=2"
                   ]
    it "writes the final workspace including .kiln-state" $ do
      let (_, final) = runSession (ws [hello]) [SBuild [] 1]
      fmap fileContent (lookupFile ".kiln-state" final)
        `shouldBe` Just (BC.pack "kiln-state 1\nstep out/hello.txt\ncmd write(\"hello\\n\")\nout out/hello.txt a9bc80cca21f28b3\nend\n")
    it "leaves the workspace untouched after a configuration error" $ do
      let (_, final) = runSession (ws [("main.kiln", "abort \"x\"\n")]) [SBuild [] 1]
      paths final `shouldBe` ["main.kiln"]
