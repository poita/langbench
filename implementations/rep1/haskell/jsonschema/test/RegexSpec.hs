{-# LANGUAGE OverloadedStrings #-}
module RegexSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import JsonSchema.Regex

matchesP :: Text -> Text -> Bool
matchesP pat subject = either (error . ("bad pattern: " ++)) (`regexSearch` subject) (compileRegex pat)

spec :: Spec
spec = do
  it "searches rather than anchoring" $ do
    matchesP "bar" "foobarbaz" `shouldBe` True
    matchesP "^bar" "foobar" `shouldBe` False
    matchesP "bar$" "foobar" `shouldBe` True

  it "supports alternation, groups and quantifiers" $ do
    matchesP "^(a|bc)+d$" "abcad" `shouldBe` True
    matchesP "^(?:ab){2,3}$" "ababab" `shouldBe` True
    matchesP "^(?:ab){2,3}$" "abababab" `shouldBe` False
    matchesP "^a{2,}$" "aaaa" `shouldBe` True
    matchesP "^colou?r$" "color" `shouldBe` True
    matchesP "^a+?b$" "aaab" `shouldBe` True

  it "treats a malformed brace as a literal" $ do
    matchesP "a{" "a{" `shouldBe` True
    matchesP "a{,3}" "a{,3}" `shouldBe` True

  it "handles classes and escapes" $ do
    matchesP "^[a-c-]+$" "ab-c" `shouldBe` True
    matchesP "^[^0-9]+$" "ab1" `shouldBe` False
    matchesP "^\\d+\\s\\w+$" "12 ab_" `shouldBe` True
    matchesP "^[\\d\\s]+$" "1 2" `shouldBe` True
    matchesP "^\\x41\\u0042\\cJ$" "AB\n" `shouldBe` True
    matchesP "^[\\b]$" "\b" `shouldBe` True
    matchesP "^\\.\\*$" ".*" `shouldBe` True

  it "matches over code points" $ do
    matchesP "^.$" "💩" `shouldBe` True
    matchesP "^\\uD83D\\uDCA9$" "💩" `shouldBe` True
    matchesP "^[💩]$" "💩" `shouldBe` True
    matchesP "^..$" "é" `shouldBe` False

  it "excludes line terminators from dot" $ do
    matchesP "^.$" "\n" `shouldBe` False
    matchesP "^.$" "\x2028" `shouldBe` False

  it "uses ASCII word boundaries and a strict end anchor" $ do
    matchesP "\\bcat\\b" "\233cat " `shouldBe` True
    matchesP "\\Bcat" "concat" `shouldBe` True
    matchesP "^a$" "a\n" `shouldBe` False

  it "never backtracks exponentially" $ do
    matchesP "^(a*)*b$" (T.replicate 5000 "a") `shouldBe` False
    matchesP "(a|aa)+$" (T.replicate 5000 "a" <> "b") `shouldBe` False

  it "reports malformed patterns" $ do
    compileRegex "(" `shouldSatisfy` isLeft'
    compileRegex "[a" `shouldSatisfy` isLeft'
    compileRegex "*a" `shouldSatisfy` isLeft'
  where
    isLeft' = either (const True) (const False)
