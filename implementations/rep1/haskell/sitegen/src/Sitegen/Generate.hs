{-# LANGUAGE OverloadedStrings #-}

-- | Turning a site source into the files of the generated site.
module Sitegen.Generate
  ( SiteSource (..)
  , OutputFile (..)
  , generate
  ) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T

import Sitegen.Content
import Sitegen.Feed
import Sitegen.Site
import Sitegen.Template
import Sitegen.Toml

-- | Everything read from the input directory except the static files.
data SiteSource = SiteSource
  { srcConfig :: Text
  -- ^ The text of @site.toml@.
  , srcPosts :: [(FilePath, Text)]
  -- ^ File name and contents of each @content/posts/*.md@.
  , srcPages :: [(FilePath, Text)]
  -- ^ File name and contents of each @content/pages/*.md@.
  , srcTemplates :: [(Text, Text)]
  -- ^ Name and source (with one trailing newline already removed) of each
  -- template.
  }
  deriving (Eq, Show)

-- | A generated text file at a path relative to the output directory.
data OutputFile = OutputFile
  { outPath :: FilePath
  , outContents :: Text
  }
  deriving (Eq, Show)

-- | Generate every page, the feed and the sitemap.
generate :: SiteSource -> Either String [OutputFile]
generate src = do
  cfg <- parseConfig (srcConfig src)
  posts <- mapM (uncurry parsePost) (srcPosts src)
  pages <- mapM (uncurry parsePage) (srcPages src)
  let site = buildSite cfg posts pages
      tpls = mkTemplates (srcTemplates src)
      views = buildViews site
      page tplName path vars = do
        out <- either (\k -> Left (T.unpack tplName ++ " (" ++ path ++ "): error: " ++ errorKindName k)) Right
                 (renderTemplate tpls tplName (vShared views ++ vars))
        Right (OutputFile path out)
  indexFiles <- mapM (\n -> page "index.html" (indexPath n) (indexVars views n)) (indexPageNumbers site)
  postFiles <- mapM (\(p, v) -> page "post.html" ("posts/" ++ T.unpack (postSlug p) ++ "/index.html") [("post", v)])
                 (zip (sitePosts site) (vPosts views))
  pageFiles <- mapM (\(p, v) -> page "page.html" (T.unpack (pageSlug p) ++ "/index.html") [("page", v)])
                 (zip (sitePages site) (vPages' views))
  tagsFile <- page "tags.html" "tags/index.html" []
  tagFiles <- mapM (\(t, (v, ps)) -> page "tag.html" ("tags/" ++ T.unpack (tagSlugOf t) ++ "/index.html") [("tag", v), ("posts", ps)])
                 (zip (siteTags site) (vTagPages views))
  Right
    ( indexFiles ++ postFiles ++ pageFiles ++ [tagsFile] ++ tagFiles
        ++ [OutputFile "feed.xml" (renderFeed site), OutputFile "sitemap.xml" (renderSitemap site)]
    )
  where
    indexPath 1 = "index.html"
    indexPath n = "page/" ++ show n ++ "/index.html"

-- ---------------------------------------------------------------------------
-- Template values, built once and shared by every page that shows them.

data Views = Views
  { vShared :: [(Text, Value)]
  , vPosts :: [Value]
  -- ^ Post objects in canonical order.
  , vPages' :: [Value]
  , vTagPages :: [(Value, Value)]
  -- ^ For each tag: the tag object and its @posts@ list.
  , vIndexPosts :: Int -> Value
  , vPagination :: Int -> Value
  }

str :: Text -> Value
str = VString

indexVars :: Views -> Int -> [(Text, Value)]
indexVars v n = [("posts", vIndexPosts v n), ("pagination", vPagination v n)]

buildViews :: Site -> Views
buildViews site =
  Views
    { vShared = [("site", siteValue), ("tags", mkList tagLinks), ("pages", mkList pageLinks)]
    , vPosts = postValues
    , vPages' = pageValues
    , vTagPages = zipWith tagPage (siteTags site) [0 :: Int ..]
    , vIndexPosts = \n -> mkList (take per (drop ((n - 1) * per) postValues))
    , vPagination = pagination
    }
  where
    cfg = siteConfig site
    base = cfgBaseUrl cfg
    per = cfgPostsPerPage cfg
    posts = sitePosts site
    nPosts = length posts
    pages = totalPages site

    siteValue = mkDict [(k, tomlValue v) | (k, v) <- cfgRaw cfg]
    tomlValue v = case v of
      TomlString s -> VString s
      TomlInt i -> VInt i
      TomlBool b -> VBool b
      TomlArray xs -> mkList (map VString xs)

    tagCount = Map.fromList [(tagName t, length (tagPosts t)) | t <- siteTags site]
    tagLinkOf t =
      mkDict
        [ ("name", str (tagName t)), ("slug", str (tagSlugOf t)), ("url", str (tagUrl t))
        , ("post_count", VInt (toInteger (length (tagPosts t)))) ]
    tagLinks = map tagLinkOf (siteTags site)
    tagLinkByName = Map.fromList [(tagName t, l) | (t, l) <- zip (siteTags site) tagLinks]
    pageLinks =
      [mkDict [("title", str (pageTitle p)), ("slug", str (pageSlug p)), ("url", str (pageUrl p))] | p <- sitePages site]

    postLink p =
      mkDict
        [ ("title", str (postTitle p)), ("slug", str (postSlug p)), ("url", str (postUrl p))
        , ("permalink", str (base <> postUrl p)), ("date", str (postDate p))
        , ("date_long", str (dateLong (postDate p))) ]
    postLinks = map postLink posts
    neighbours =
      zip3 posts (VNone : postLinks) (drop 1 postLinks ++ [VNone])
    postValues = [postValue p newer older | (p, newer, older) <- neighbours]
    postValue p newer older =
      mkDict
        [ ("title", str (postTitle p)), ("slug", str (postSlug p)), ("url", str (postUrl p))
        , ("permalink", str (base <> postUrl p)), ("date", str (postDate p))
        , ("date_long", str (dateLong (postDate p)))
        , ("tags", mkList [Map.findWithDefault VNone t tagLinkByName | t <- postTags p])
        , ("content", str (postContent p)), ("excerpt", str (postExcerpt p))
        , ("older", older), ("newer", newer) ]
    postValueBySlug = Map.fromList (zip (map postSlug posts) postValues)

    pageValues =
      [ mkDict
          [ ("title", str (pageTitle p)), ("slug", str (pageSlug p)), ("url", str (pageUrl p))
          , ("permalink", str (base <> pageUrl p)), ("content", str (pageContent p)) ]
      | p <- sitePages site ]

    tagPage t _ =
      let ps = mkList [Map.findWithDefault VNone (postSlug p) postValueBySlug | p <- tagPosts t]
          count = Map.findWithDefault 0 (tagName t) tagCount
       in ( mkDict
              [ ("name", str (tagName t)), ("slug", str (tagSlugOf t)), ("url", str (tagUrl t))
              , ("post_count", VInt (toInteger count)), ("posts", ps) ]
          , ps )

    pagination n =
      mkDict
        [ ("number", VInt (toInteger n)), ("total_pages", VInt (toInteger pages))
        , ("total_posts", VInt (toInteger nPosts))
        , ("has_prev", VBool (n > 1)), ("has_next", VBool (n < pages))
        , ("prev_url", if n > 1 then str (indexUrl (n - 1)) else VNone)
        , ("next_url", if n < pages then str (indexUrl (n + 1)) else VNone)
        , ( "links"
          , mkList
              [ mkDict [("number", VInt (toInteger i)), ("url", str (indexUrl i)), ("current", VBool (i == n))]
              | i <- [1 .. pages] ] ) ]
