{-# LANGUAGE OverloadedStrings #-}

module Sitegen.ContentSpec (spec) where

import Data.Either (isLeft)
import qualified Data.Text as T
import Test.Hspec
import Test.QuickCheck

import Sitegen.Content

spec :: Spec
spec = do
  describe "splitFrontMatter" $ do
    it "splits at the first whole-line +++" $
      splitFrontMatter "+++\na = 1\n+++\nbody\n+++\nmore\n"
        `shouldBe` Right ("a = 1", "body\n+++\nmore\n")

    it "ignores +++ inside longer lines" $
      splitFrontMatter "+++\ns = \"+++\"\nt = \"a +++\"\n+++\nx"
        `shouldBe` Right ("s = \"+++\"\nt = \"a +++\"", "x")

    it "gives an empty body when the delimiter ends the file" $
      splitFrontMatter "+++\na = 1\n+++" `shouldBe` Right ("a = 1", "")

    it "accepts empty front matter" $
      splitFrontMatter "+++\n+++\nhi" `shouldBe` Right ("", "hi")

    it "rejects a file without front matter" $
      splitFrontMatter "hello" `shouldSatisfy` isLeft

  describe "parsePost" $ do
    let src = "+++\ntitle = \"T\"\ndate = \"2024-01-02\"\ntags = [\"a\", \"b\", \"a\"]\n+++\nHello *x*\n\nmore\n"
    it "reads the front matter and applies defaults" $ do
      let p = either error id (parsePost "my-post.md" src)
      postTitle p `shouldBe` "T"
      postSlug p `shouldBe` "my-post"
      postDate p `shouldBe` "2024-01-02"
      postTags p `shouldBe` ["a", "b"]
      postDraft p `shouldBe` False

    it "converts content and the first-block excerpt" $ do
      let p = either error id (parsePost "p.md" src)
      postContent p `shouldBe` "<p>Hello <em>x</em></p>\n<p>more</p>\n"
      postExcerpt p `shouldBe` "<p>Hello <em>x</em></p>\n"

    it "takes the slug from the front matter when present" $ do
      let p = either error id (parsePost "f.md" "+++\ntitle = \"T\"\ndate = \"2024-01-02\"\nslug = \"s\"\ndraft = true\n+++\n")
      postSlug p `shouldBe` "s"
      postDraft p `shouldBe` True

    it "rejects a post without a date" $
      parsePost "f.md" "+++\ntitle = \"T\"\n+++\n" `shouldSatisfy` isLeft

  describe "parsePage" $
    it "reads a page" $ do
      let p = either error id (parsePage "about.md" "+++\ntitle = \"About\"\n+++\n# About\n")
      pageSlug p `shouldBe` "about"
      pageContent p `shouldBe` "<h1>About</h1>\n"

  describe "excerptSource" $ do
    it "skips leading blank lines and stops at the next blank line" $
      excerptSource " \n\t\nfirst\nsecond\n\nthird" `shouldBe` "first\nsecond"
    it "is empty for a blank body" $
      excerptSource "  \n\n" `shouldBe` ""
    it "cuts a fenced block at its first blank line" $
      excerptSource "```\na\n\nb\n```" `shouldBe` "```\na"

  describe "tagSlug" $ do
    it "lowercases and replaces other characters with dashes" $ do
      tagSlug "Web Development" `shouldBe` "web-development"
      tagSlug "C++" `shouldBe` "c"
      tagSlug "Rust 2024" `shouldBe` "rust-2024"
      tagSlug "--a__b--" `shouldBe` "a-b"
    it "only produces lowercase letters, digits and single inner dashes" $
      property $ \s ->
        let slug = T.unpack (tagSlug (T.pack s))
         in all (`elem` ['a' .. 'z'] ++ ['0' .. '9'] ++ "-") slug
              && take 1 slug /= "-" && take 1 (reverse slug) /= "-"
              && not ("--" `T.isInfixOf` T.pack slug)
    it "is idempotent" $
      property $ \s -> tagSlug (tagSlug (T.pack s)) == tagSlug (T.pack s)

  describe "dateLong" $
    it "writes month names and drops the day's leading zero" $ do
      dateLong "2024-03-05" `shouldBe` "March 5, 2024"
      dateLong "1999-12-25" `shouldBe` "December 25, 1999"
      dateLong "2000-01-31" `shouldBe` "January 31, 2000"
