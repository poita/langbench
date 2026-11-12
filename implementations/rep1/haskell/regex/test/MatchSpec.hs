{-# LANGUAGE OverloadedStrings #-}
module MatchSpec (spec) where

import qualified Data.ByteString.Char8 as BC
import Test.Hspec

import Regex

-- | Run a pattern on a subject, giving (start, end, groups).
run :: String -> String -> Maybe (Int, Int, [Maybe (Int, Int)])
run pat subj = case compile pat of
  Left e   -> error (show e)
  Right re -> (\(Match s e g) -> (s, e, g)) <$> search re (BC.pack subj)

(=~) :: (String, String) -> Maybe (Int, Int, [Maybe (Int, Int)]) -> Expectation
(p, s) =~ expected = run p s `shouldBe` expected

spec :: Spec
spec = do
  describe "specification examples" $ do
    it "takes the first alternative, not the longest" $ do
      ("(a|ab)(c|bcd)(d*)", "abcd") =~ Just (0, 4, [Just (0, 1), Just (1, 4), Just (4, 4)])
      ("a|ab", "ab") =~ Just (0, 1, [])
    it "prefers the leftmost match" $ do
      ("a*", "bbb") =~ Just (0, 0, [])
      ("a*", "") =~ Just (0, 0, [])
    it "handles nested quantifiers" $ do
      ("^(a+)+$", "aaaa") =~ Just (0, 4, [Just (0, 4)])
      ("^(a+)+$", "aaab") =~ Nothing
      ("(a*)*b", "aab") =~ Just (0, 3, [Just (2, 2)])
      ("(a*)*b", "ccc") =~ Nothing
    it "keeps captures from earlier iterations" $ do
      ("(a|(b))+", "ba") =~ Just (0, 2, [Just (1, 2), Just (0, 1)])
      ("(a|(b))+", "ab") =~ Just (0, 2, [Just (1, 2), Just (1, 2)])
    it "leaves skipped groups unset" $ do
      ("(a){0}b|(c)?(d)", "xb") =~ Just (1, 2, [Nothing, Nothing, Nothing])
      ("(a){0}b|(c)?(d)", "xcd") =~ Just (1, 3, [Nothing, Just (1, 2), Just (2, 3)])
      ("(a){0}b|(c)?(d)", "d") =~ Just (0, 1, [Nothing, Nothing, Just (0, 1)])
    it "runs required empty iterations" $
      ("(a*){3}", "") =~ Just (0, 0, [Just (0, 0)])
    it "searches start positions in order" $ do
      ("[^a-c]\\d{2,3}x?", "zz123xx") =~ Just (1, 6, [])
      ("[^a-c]\\d{2,3}x?", "abc9") =~ Nothing
      ("x$|^(y)?z", "xz") =~ Nothing
      ("x$|^(y)?z", "yz") =~ Just (0, 2, [Just (0, 1)])
  describe "anchors" $ do
    it "never matches a^b" $ ("a^b", "ab") =~ Nothing
    it "matches $ only at the end" $ do
      ("a$", "aa") =~ Just (1, 2, [])
      ("$", "abc") =~ Just (3, 3, [])
    it "tries only start 0 for ^ patterns" $ do
      ("^b", "ab") =~ Nothing
      ("^(a|^b)", "ba") =~ Just (0, 1, [Just (0, 1)])
  describe "classes and escapes" $ do
    it "handles sets" $ do
      ("\\w+", "  foo_1 ") =~ Just (2, 7, [])
      ("\\S+", "  ab ") =~ Just (2, 4, [])
      ("[\\d.]+", "v1.25!") =~ Just (1, 5, [])
      ("[^\\s]+", " xy ") =~ Just (1, 3, [])
    it "treats \\ followed by punctuation as a literal" $
      ("\\(\\)\\ ", "() ") =~ Just (0, 3, [])
  describe "repetition" $ do
    it "is greedy and backtracks" $ do
      ("a*ab", "aaab") =~ Just (0, 4, [])
      ("(a|aa)+c", "aaaaaaaaaaaaaaaaaaaaaaaab") =~ Nothing
    it "respects bounds" $ do
      ("a{2,3}", "aaaa") =~ Just (0, 3, [])
      ("a{2,3}", "a") =~ Nothing
      ("(ab){2}", "ababab") =~ Just (0, 4, [Just (2, 4)])
      ("a{0}", "a") =~ Just (0, 0, [])
    it "ends the loop on an optional empty iteration" $
      ("(a?)*", "b") =~ Just (0, 0, [Just (0, 0)])
    it "copes with long subjects" $ do
      let s = replicate 100000 'a'
      run ".*b" (take 2000 s) `shouldBe` Nothing
      run "(a|b)*$" s `shouldBe` Just (0, 100000, [Just (99999, 100000)])
  describe "API" $ do
    it "reports the number of groups" $
      fmap groupCount (compile "(a)(b(c))") `shouldBe` Right 3
    it "offers a boolean test" $ do
      case compile "b+" of
        Left e   -> expectationFailure (show e)
        Right re -> do
          matches re "abba" `shouldBe` True
          matches re "aaa" `shouldBe` False
    it "returns syntax errors" $
      either errorMessage (const "ok") (compile "(a") `shouldNotBe` "ok"
