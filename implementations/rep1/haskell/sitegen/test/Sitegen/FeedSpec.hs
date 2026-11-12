{-# LANGUAGE OverloadedStrings #-}

module Sitegen.FeedSpec (spec) where

import qualified Data.Text as T
import Test.Hspec

import Sitegen.Content
import Sitegen.Feed
import Sitegen.Site

site :: Int -> [(String, String)] -> Site
site perPage posts =
  case parseConfig
    (T.unlines
       [ "title = \"Tom & <Jerry>\"", "base_url = \"https://e.org/b\"", "author = \"A \\\"Q\\\"\""
       , "posts_per_page = " <> T.pack (show perPage) ]) of
    Left err -> error err
    Right cfg ->
      buildSite cfg
        [ either error id (parsePost (slug ++ ".md")
            (T.pack ("+++\ntitle = \"" ++ slug ++ " & co\"\ndate = \"" ++ date ++ "\"\n+++\nBody <b> & more\n")))
        | (slug, date) <- posts ]
        []

spec :: Spec
spec = do
  describe "escaping" $ do
    it "escapes text" $ escapeText "a&b<c>d\"e'f" `shouldBe` "a&amp;b&lt;c&gt;d\"e'f"
    it "escapes attributes" $ escapeAttr "a&b<c>d\"e'f" `shouldBe` "a&amp;b&lt;c&gt;d&quot;e'f"

  describe "renderFeed" $ do
    it "uses the epoch for a site without posts" $
      renderFeed (site 3 [])
        `shouldBe` T.unlines
          [ "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
          , "<feed xmlns=\"http://www.w3.org/2005/Atom\">"
          , "  <title>Tom &amp; &lt;Jerry&gt;</title>"
          , "  <id>https://e.org/b/</id>"
          , "  <updated>1970-01-01T00:00:00Z</updated>"
          , "  <link href=\"https://e.org/b/\" rel=\"alternate\"/>"
          , "  <link href=\"https://e.org/b/feed.xml\" rel=\"self\"/>"
          , "  <author>"
          , "    <name>A \"Q\"</name>"
          , "  </author>"
          , "</feed>" ]

    it "lists only the first posts_per_page entries, newest first" $ do
      let out = renderFeed (site 1 [("old", "2023-01-01"), ("new", "2024-06-30")])
      out `shouldSatisfy` T.isInfixOf "<updated>2024-06-30T00:00:00Z</updated>"
      T.count "<entry>" out `shouldBe` 1
      out `shouldSatisfy` T.isInfixOf "<id>https://e.org/b/posts/new/</id>"

    it "escapes the HTML content without re-indenting it" $
      renderFeed (site 1 [("p", "2024-01-01")])
        `shouldSatisfy` T.isInfixOf
          "    <content type=\"html\">&lt;p&gt;Body &amp;lt;b&amp;gt; &amp;amp; more&lt;/p&gt;\n</content>\n  </entry>\n</feed>\n"

  describe "renderSitemap" $
    it "lists index pages, posts, pages and tags in order" $ do
      let out = renderSitemap (site 1 [("a", "2024-01-01"), ("b", "2024-02-01")])
      map T.strip (filter (T.isInfixOf "<loc>") (T.lines out))
        `shouldBe` [ "<loc>https://e.org/b/</loc>", "<loc>https://e.org/b/page/2/</loc>"
                   , "<loc>https://e.org/b/posts/b/</loc>", "<loc>https://e.org/b/posts/a/</loc>"
                   , "<loc>https://e.org/b/tags/</loc>" ]
      T.count "<lastmod>" out `shouldBe` 2
      out `shouldSatisfy` T.isInfixOf "<lastmod>2024-02-01</lastmod>"
