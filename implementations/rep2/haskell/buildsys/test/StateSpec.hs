module StateSpec (spec) where

import qualified Data.ByteString.Char8 as BC
import qualified Data.Map.Strict as M
import Test.Hspec
import Test.QuickCheck

import Kiln.Hash
import Kiln.State
import Kiln.Workspace

genPath :: Gen BC.ByteString
genPath = do
  n <- choose (1, 3)
  comps <- vectorOf n (BC.pack <$> listOf1 (elements ['a' .. 'f']))
  pure (BC.intercalate "/" comps)

genFiles :: Gen [(BC.ByteString, Hash)]
genFiles = listOf ((,) <$> genPath <*> arbitrary)

genEntry :: Gen (BC.ByteString, Entry)
genEntry = do
  ins <- genFiles
  deps <- genFiles
  out <- (,) <$> genPath <*> arbitrary
  outs <- genFiles
  cmd <- BC.pack <$> listOf1 (elements ("abc() \"," :: String))
  pure (fst out, Entry cmd ins deps (out : outs))

spec :: Spec
spec = do
  describe "hashing" $ do
    it "matches the specified vectors" $ do
      renderHash (fnv1a "") `shouldBe` "cbf29ce484222325"
      renderHash (fnv1a "hello\n") `shouldBe` "a9bc80cca21f28b3"
      renderHash (fnv1a "abc\n") `shouldBe` "fc17b183ee074373"
    it "renders and parses round-trip" $
      property $ \h -> parseHash (renderHash h) == Just h
  describe "parseState / renderState" $ do
    it "round-trips well-formed states" $
      forAll (M.fromList <$> listOf genEntry) $ \m -> parseState (renderState m) == m
    let good = "kiln-state 1\nstep out/a\ncmd copy()\nin src/a 0123456789abcdef\nout out/a 0123456789abcdef\nend\n"
    it "accepts a valid file" $ M.keys (parseState good) `shouldBe` ["out/a"]
    mapM_
      (\(name, bad) -> it ("treats " ++ name ++ " as empty") $ parseState bad `shouldBe` M.empty)
      [ ("a missing final newline", BC.init good)
      , ("a wrong header", "kiln-state 2\n")
      , ("an uppercase hash", BC.map (\c -> if c == 'f' then 'F' else c) good)
      , ("a step key that differs from the first out", "kiln-state 1\nstep out/b\ncmd c()\nout out/a 0123456789abcdef\nend\n")
      , ("an entry without out lines", "kiln-state 1\nstep out/a\ncmd c()\nend\n")
      , ("an empty cmd", "kiln-state 1\nstep out/a\ncmd \nout out/a 0123456789abcdef\nend\n")
      , ("misordered sections", "kiln-state 1\nstep out/a\ncmd c()\nout out/a 0123456789abcdef\nin x 0123456789abcdef\nend\n")
      , ("an unterminated entry", "kiln-state 1\nstep out/a\ncmd c()\nout out/a 0123456789abcdef\n")
      , ("duplicate step keys", BC.append good (BC.drop 13 good))
      , ("a stray line", "kiln-state 1\nhello\n")
      , ("a bad path", "kiln-state 1\nstep ../a\ncmd c()\nout ../a 0123456789abcdef\nend\n")
      ]
  describe "isFresh" $ do
    let files = ws' [("src/a", "A\n"), ("out/a", "B\n")]
        ws' = fromFiles
        h c = fnv1a c
        entry = Entry "copy()" [("src/a", h "A\n")] [] [("out/a", h "B\n")]
        fresh e = isFresh files e "copy()" ["out/a"] ["src/a"]
    it "is fresh when everything matches" $ fresh (Just entry) `shouldBe` True
    it "is stale without an entry" $ fresh Nothing `shouldBe` False
    it "is stale when the command changes" $
      isFresh files (Just entry) "copy2()" ["out/a"] ["src/a"] `shouldBe` False
    it "is stale when a recorded hash differs" $
      fresh (Just entry {entOuts = [("out/a", 1)]}) `shouldBe` False
    it "is stale when a discovered dependency disappears" $
      fresh (Just entry {entDeps = [("src/gone", 1)]}) `shouldBe` False
