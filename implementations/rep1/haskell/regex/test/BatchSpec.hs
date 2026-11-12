module BatchSpec (spec) where

import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy.Char8 as BL
import Test.Hspec

import Regex.Batch

run :: String -> (String, Maybe BatchError)
run inp =
  let (b, e) = batchToBuilder (processBatch (BC.pack inp))
  in (BL.unpack (BB.toLazyByteString b), e)

spec :: Spec
spec = do
  it "reproduces the first worked example" $
    run (unlines ["3", "(a|ab)(c|bcd)(d*)", "1", "abcd", "a*", "2", "bbb", "", "^(a+)+$", "2", "aaaa", "aaab"])
      `shouldBe` ("match 0 4|0,1|1,4|4,4\nmatch 0 0\nmatch 0 0\nmatch 0 4|0,4\nno\n", Nothing)
  it "takes lines verbatim, including empty and space-only ones" $
    run (unlines ["2", " a", "3", "", " a ", "a", "", "0", "1", "5"])
      `shouldBe` ("no\nmatch 0 2\nno\n", Nothing)
  it "allows patterns with zero subjects, and the last line without newline" $
    run "2\nx\n0\ny\n1\ny"
      `shouldBe` ("match 0 1\n", Nothing)
  it "prints nothing when every pattern has M = 0" $
    run "1\nx\n0\n" `shouldBe` ("", Nothing)
  it "reports unset groups as -" $
    run "1\n(a)|(b)\n1\nb\n" `shouldBe` ("match 0 1|-|0,1\n", Nothing)
  it "reports a bad pattern after the earlier output" $
    case run "2\na\n1\na\n(\n1\nx\n" of
      (out, Just (BadPattern 2 "(" _)) -> out `shouldBe` "match 0 1\n"
      other -> expectationFailure (show other)
  it "reports truncated input" $
    snd (run "1\na\n2\nx\n") `shouldBe` Just (MalformedInput "missing subject line")
