module StateSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Test.Hspec
import Test.QuickCheck

import Kiln.State

genPath :: Gen BS.ByteString
genPath = do
  n <- choose (1, 3)
  parts <- vectorOf n ((:) <$> elements ['a' .. 'z'] <*> listOf (elements (concat ["abcxyz", "_.-+09"] :: String)))
  pure (BS.intercalate "/" (map (BS.pack . map (fromIntegral . fromEnum)) parts))

genEntry :: Gen (BS.ByteString, Entry)
genEntry = do
  key <- ("out/" <>) <$> genPath
  cmd <- elements ["concat()", "write(\"a b\\n\")", "indent(3)"]
  ins <- listOf ((,) <$> genPath <*> arbitrary)
  deps <- listOf ((,) <$> genPath <*> arbitrary)
  extra <- listOf ((,) <$> (("out/" <>) <$> genPath) <*> arbitrary)
  h <- arbitrary
  pure (key, Entry cmd ins deps ((key, h) : extra))

spec :: Spec
spec = do
  let valid =
        "kiln-state 1\nstep out/a\ncmd write(\"x\")\nin src/a 0123456789abcdef\nout out/a 0123456789abcdef\nend\n"
  it "parses a valid file" $ Map.keys (parseState valid) `shouldBe` ["out/a"]
  it "renders a valid file back to itself" $ renderState (parseState valid) `shouldBe` valid
  it "accepts the header alone" $ parseState "kiln-state 1\n" `shouldBe` Map.empty
  it "round-trips arbitrary states" $
    property $ forAll (listOf genEntry) $ \es ->
      let m = Map.fromList es in parseState (renderState m) === m
  describe "rejects (taking the state as empty)" $ do
    let rejects name s = it name (parseState s `shouldBe` Map.empty)
    rejects "a bad header" "kiln-state 2\n"
    rejects "a missing final newline" "kiln-state 1\nstep out/a\ncmd c()\nout out/a 0123456789abcdef\nend"
    rejects "an unterminated entry" "kiln-state 1\nstep out/a\ncmd c()\nout out/a 0123456789abcdef\n"
    rejects "a step key differing from the first out" "kiln-state 1\nstep out/a\ncmd c()\nout out/b 0123456789abcdef\nend\n"
    rejects "an entry with no out" "kiln-state 1\nstep out/a\ncmd c()\nend\n"
    rejects "uppercase hex" "kiln-state 1\nstep out/a\ncmd c()\nout out/a 0123456789ABCDEF\nend\n"
    rejects "an empty cmd" "kiln-state 1\nstep out/a\ncmd \nout out/a 0123456789abcdef\nend\n"
    rejects "misordered sections" "kiln-state 1\nstep out/a\ncmd c()\nout out/a 0123456789abcdef\nin src/a 0123456789abcdef\nend\n"
    rejects "duplicate keys"
      ( "kiln-state 1\nstep out/a\ncmd c()\nout out/a 0123456789abcdef\nend\n"
          <> "step out/a\ncmd c()\nout out/a 0123456789abcdef\nend\n"
      )
    rejects "a stray line" "kiln-state 1\nhello\n"
    rejects "a bad path" "kiln-state 1\nstep out/../a\ncmd c()\nout out/../a 0123456789abcdef\nend\n"
