{-# LANGUAGE OverloadedStrings #-}

-- | The Atom feed and the sitemap.
module Sitegen.Feed
  ( renderFeed
  , renderSitemap
  , escapeText
  , escapeAttr
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Sitegen.Content
import Sitegen.Site

-- | Escape @&@, @<@ and @>@.
escapeText :: Text -> Text
escapeText = T.replace ">" "&gt;" . T.replace "<" "&lt;" . T.replace "&" "&amp;"

-- | Like 'escapeText', and also @"@.
escapeAttr :: Text -> Text
escapeAttr = T.replace "\"" "&quot;" . escapeText

-- | The Atom feed: the first @posts_per_page@ posts, newest first. The
-- @updated@ time is the newest post's date, so the output never depends on
-- the clock.
renderFeed :: Site -> Text
renderFeed site = T.unlines (header ++ concatMap entry posts ++ ["</feed>"]) `dropFinalNewline` ()
  where
    cfg = siteConfig site
    base = cfgBaseUrl cfg
    posts = take (cfgPostsPerPage cfg) (sitePosts site)
    updated = case sitePosts site of
      (p : _) -> postDate p <> "T00:00:00Z"
      [] -> "1970-01-01T00:00:00Z"
    header =
      [ "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
      , "<feed xmlns=\"http://www.w3.org/2005/Atom\">"
      , "  <title>" <> escapeText (cfgTitle cfg) <> "</title>"
      , "  <id>" <> escapeText (base <> "/") <> "</id>"
      , "  <updated>" <> updated <> "</updated>"
      , "  <link href=\"" <> escapeAttr (base <> "/") <> "\" rel=\"alternate\"/>"
      , "  <link href=\"" <> escapeAttr (base <> "/feed.xml") <> "\" rel=\"self\"/>"
      , "  <author>"
      , "    <name>" <> escapeText (cfgAuthor cfg) <> "</name>"
      , "  </author>"
      ]
    entry p =
      let link = base <> postUrl p
       in [ "  <entry>"
          , "    <title>" <> escapeText (postTitle p) <> "</title>"
          , "    <id>" <> escapeText link <> "</id>"
          , "    <updated>" <> postDate p <> "T00:00:00Z</updated>"
          , "    <link href=\"" <> escapeAttr link <> "\" rel=\"alternate\"/>"
          , "    <content type=\"html\">" <> escapeText (postContent p) <> "</content>"
          , "  </entry>"
          ]
    -- T.unlines already ends with a newline, which is what the format needs
    dropFinalNewline t () = t

-- | The sitemap: index pages, posts (with @lastmod@), pages, the tag index
-- and the tags.
renderSitemap :: Site -> Text
renderSitemap site = T.unlines (["<?xml version=\"1.0\" encoding=\"utf-8\"?>", "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">"] ++ concat urls ++ ["</urlset>"])
  where
    base = cfgBaseUrl (siteConfig site)
    url loc extra = ["  <url>", "    <loc>" <> escapeText (base <> loc) <> "</loc>"] ++ extra ++ ["  </url>"]
    urls =
      [url (indexUrl n) [] | n <- indexPageNumbers site]
        ++ [url (postUrl p) ["    <lastmod>" <> postDate p <> "</lastmod>"] | p <- sitePosts site]
        ++ [url (pageUrl p) [] | p <- sitePages site]
        ++ [url tagsUrl []]
        ++ [url (tagUrl t) [] | t <- siteTags site]
