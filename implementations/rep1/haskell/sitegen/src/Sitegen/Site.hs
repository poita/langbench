{-# LANGUAGE OverloadedStrings #-}

-- | The content model: configuration, published posts and pages in their
-- canonical orders, tags, URLs and pagination.
module Sitegen.Site
  ( SiteConfig (..)
  , parseConfig
  , Tag (..)
  , Site (..)
  , buildSite
  , totalPages
  , indexPageNumbers
  , indexUrl
  , postUrl
  , pageUrl
  , tagUrl
  , tagsUrl
  ) where

import Data.List (sortBy)
import qualified Data.Map.Strict as Map
import Data.Ord (comparing)
import Data.Text (Text)
import qualified Data.Text as T

import Sitegen.Content
import Sitegen.Toml

-- | The site configuration from @site.toml@.
data SiteConfig = SiteConfig
  { cfgTitle :: Text
  , cfgBaseUrl :: Text
  -- ^ Without a trailing slash.
  , cfgAuthor :: Text
  , cfgPostsPerPage :: Int
  , cfgRaw :: TomlDoc
  -- ^ The whole document, in file order.
  }
  deriving (Eq, Show)

-- | Read the configuration from the text of @site.toml@.
parseConfig :: Text -> Either String SiteConfig
parseConfig src = do
  doc <- parseToml src
  title <- need (lookupString "title" doc) "title"
  base <- need (lookupString "base_url" doc) "base_url"
  author <- need (lookupString "author" doc) "author"
  perPage <- need (lookupInt "posts_per_page" doc) "posts_per_page"
  if perPage < 1 then Left "posts_per_page must be at least 1" else Right ()
  Right (SiteConfig title base author (fromInteger perPage) doc)
  where
    need m k = maybe (Left ("site.toml: missing or mistyped key " ++ k)) Right m

-- | A tag with the published posts that carry it.
data Tag = Tag
  { tagName :: Text
  , tagSlugOf :: Text
  , tagPosts :: [Post]
  -- ^ In canonical order.
  }

-- | A site ready to be rendered.
data Site = Site
  { siteConfig :: SiteConfig
  , sitePosts :: [Post]
  -- ^ Published posts, newest first.
  , sitePages :: [Page]
  -- ^ Published pages, by slug.
  , siteTags :: [Tag]
  -- ^ Existing tags, by slug.
  }

-- | Drop drafts, sort, and collect the tags. Collecting tags visits each
-- (post, tag) pair once.
buildSite :: SiteConfig -> [Post] -> [Page] -> Site
buildSite cfg allPosts allPages = Site cfg posts pages tags
  where
    posts = sortBy comparePosts (filter (not . postDraft) allPosts)
    pages = sortBy (comparing pageSlug) (filter (not . pageDraft) allPages)
    byName =
      Map.fromListWith (flip (++)) [(t, [p]) | p <- posts, t <- postTags p]
    tags =
      sortBy (comparing tagSlugOf) [Tag n (tagSlug n) ps | (n, ps) <- Map.toList byName]

-- | Number of index pages: at least one.
totalPages :: Site -> Int
totalPages s = max 1 ((length (sitePosts s) + per - 1) `div` per)
  where
    per = cfgPostsPerPage (siteConfig s)

indexPageNumbers :: Site -> [Int]
indexPageNumbers s = [1 .. totalPages s]

indexUrl :: Int -> Text
indexUrl 1 = "/"
indexUrl n = "/page/" <> T.pack (show n) <> "/"

postUrl :: Post -> Text
postUrl p = "/posts/" <> postSlug p <> "/"

pageUrl :: Page -> Text
pageUrl p = "/" <> pageSlug p <> "/"

tagUrl :: Tag -> Text
tagUrl t = "/tags/" <> tagSlugOf t <> "/"

tagsUrl :: Text
tagsUrl = "/tags/"
