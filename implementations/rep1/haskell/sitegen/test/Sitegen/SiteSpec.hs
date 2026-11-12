{-# LANGUAGE OverloadedStrings #-}

module Sitegen.SiteSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Sitegen.Content
import Sitegen.Site

post :: Text -> Text -> [Text] -> Bool -> Post
post slug date tags draft =
  case parsePost (T.unpack slug ++ ".md") (src slug date tags draft) of
    Right p -> p
    Left err -> error err

src :: Text -> Text -> [Text] -> Bool -> Text
src slug date tags draft =
  T.unlines
    [ "+++"
    , "title = \"" <> slug <> "\""
    , "date = \"" <> date <> "\""
    , "tags = [" <> T.intercalate ", " ["\"" <> t <> "\"" | t <- tags] <> "]"
    , "draft = " <> (if draft then "true" else "false")
    , "+++"
    , "body"
    ]

config :: Int -> SiteConfig
config n =
  case parseConfig
    (T.unlines
       [ "title = \"S\"", "base_url = \"https://x.org\"", "author = \"A\""
       , "posts_per_page = " <> T.pack (show n) ]) of
    Right c -> c
    Left err -> error err

spec :: Spec
spec = do
  let posts =
        [ post "b" "2024-01-01" ["Web Dev", "Rust"] False
        , post "a" "2024-01-01" ["Rust"] False
        , post "c" "2024-03-01" [] False
        , post "d" "2024-05-01" ["Draft Only"] True
        ]
      site = buildSite (config 2) posts []

  it "drops drafts and orders posts newest first, ties by slug" $
    map postSlug (sitePosts site) `shouldBe` ["c", "a", "b"]

  it "collects only tags of published posts, ordered by slug" $
    map tagSlugOf (siteTags site) `shouldBe` ["rust", "web-dev"]

  it "keeps each tag's posts in canonical order" $
    map (map postSlug . tagPosts) (siteTags site) `shouldBe` [["a", "b"], ["b"]]

  it "computes the number of index pages" $ do
    totalPages site `shouldBe` 2
    totalPages (buildSite (config 3) posts []) `shouldBe` 1
    totalPages (buildSite (config 5) [] []) `shouldBe` 1

  it "builds URLs" $ do
    indexUrl 1 `shouldBe` "/"
    indexUrl 3 `shouldBe` "/page/3/"
    map postUrl (sitePosts site) `shouldBe` ["/posts/c/", "/posts/a/", "/posts/b/"]
    map tagUrl (siteTags site) `shouldBe` ["/tags/rust/", "/tags/web-dev/"]

  it "requires the four configuration keys" $
    parseConfig "title = \"x\"\n" `shouldSatisfy` either (const True) (const False)
