{-# LANGUAGE OverloadedStrings #-}

-- | Content files: front matter, posts and pages, slugs and dates.
module Sitegen.Content
  ( Post (..)
  , Page (..)
  , splitFrontMatter
  , parsePost
  , parsePage
  , excerptSource
  , tagSlug
  , dateLong
  , comparePosts
  ) where

import Data.List (nub)
import Data.Ord (comparing)
import Data.Text (Text)
import qualified Data.Text as T

import Sitegen.Markdown (markdownToHtml)
import Sitegen.Toml

-- | A blog post. 'postContent' and 'postExcerpt' are converted lazily and at
-- most once, so they can be shared by every page and the feed.
data Post = Post
  { postTitle :: Text
  , postSlug :: Text
  , postDate :: Text
  -- ^ @YYYY-MM-DD@.
  , postTags :: [Text]
  -- ^ In front-matter order, without repeats.
  , postDraft :: Bool
  , postBody :: Text
  , postContent :: Text
  -- ^ The body converted to HTML.
  , postExcerpt :: Text
  -- ^ The first block of the body converted to HTML.
  }
  deriving (Eq, Show)

-- | A standalone page.
data Page = Page
  { pageTitle :: Text
  , pageSlug :: Text
  , pageDraft :: Bool
  , pageBody :: Text
  , pageContent :: Text
  }
  deriving (Eq, Show)

-- | Split a content file into its front matter and its body. The file must
-- start with @+++@ on its own line; the front matter ends at the next line
-- that is exactly @+++@.
splitFrontMatter :: Text -> Either String (Text, Text)
splitFrontMatter t = case T.stripPrefix "+++\n" t of
  Nothing -> Left "content file does not start with a +++ line"
  Just rest -> go [] rest
  where
    go acc r =
      let (l, after) = T.break (== '\n') r
       in if l == "+++"
            then Right (T.intercalate "\n" (reverse acc), T.drop 1 after)
            else
              if T.null after
                then Left "front matter is not closed by a +++ line"
                else go (l : acc) (T.drop 1 after)

stem :: FilePath -> Text
stem name = let t = T.pack name in maybe t id (T.stripSuffix ".md" t)

requireString :: Text -> TomlDoc -> Either String Text
requireString k doc = maybe (Left ("missing string key " ++ T.unpack k)) Right (lookupString k doc)

-- | Parse a post from its file name and contents.
parsePost :: FilePath -> Text -> Either String Post
parsePost name src = do
  (front, body) <- splitFrontMatter src
  doc <- parseToml front
  title <- requireString "title" doc
  date <- requireString "date" doc
  let slug = maybe (stem name) id (lookupString "slug" doc)
      tags = nub (maybe [] id (lookupStrings "tags" doc))
      draft = maybe False id (lookupBool "draft" doc)
  Right (Post title slug date tags draft body (markdownToHtml body) (markdownToHtml (excerptSource body)))

-- | Parse a page from its file name and contents.
parsePage :: FilePath -> Text -> Either String Page
parsePage name src = do
  (front, body) <- splitFrontMatter src
  doc <- parseToml front
  title <- requireString "title" doc
  let slug = maybe (stem name) id (lookupString "slug" doc)
      draft = maybe False id (lookupBool "draft" doc)
  Right (Page title slug draft body (markdownToHtml body))

-- | The Markdown source of a body's first block: skip leading blank lines,
-- then take the following run of non-blank lines.
excerptSource :: Text -> Text
excerptSource body =
  T.intercalate "\n" (takeWhile (not . blank) (dropWhile blank (T.splitOn "\n" body)))
  where
    blank = T.all (\c -> c == ' ' || c == '\t')

-- | The slug of a tag name.
tagSlug :: Text -> Text
tagSlug name = T.dropAround (== '-') (collapse (T.map repl name))
  where
    repl c
      | c >= 'A' && c <= 'Z' = toEnum (fromEnum c + 32)
      | (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') = c
      | otherwise = '-'
    collapse = T.intercalate "-" . filter (not . T.null) . T.splitOn "-"

-- | Render @YYYY-MM-DD@ as @Month D, YYYY@.
dateLong :: Text -> Text
dateLong d = case T.splitOn "-" d of
  [y, m, day] | [(mi, "")] <- reads (T.unpack m), mi >= 1, mi <= 12, [(di, "")] <- reads (T.unpack day) ->
    T.concat [months !! (mi - 1), " ", T.pack (show (di :: Int)), ", ", y]
  _ -> d
  where
    months =
      [ "January", "February", "March", "April", "May", "June", "July"
      , "August", "September", "October", "November", "December" ]

-- | The canonical post order: newest date first, then slug ascending.
comparePosts :: Post -> Post -> Ordering
comparePosts a b = comparing postDate b a <> comparing postSlug a b
