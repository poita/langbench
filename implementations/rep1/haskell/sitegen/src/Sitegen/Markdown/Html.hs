{-# LANGUAGE OverloadedStrings #-}

-- | Rendering of the Markdown tree to HTML, byte-compatible with cmark.
module Sitegen.Markdown.Html
  ( renderBlocks
  , renderInlines
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Sitegen.Markdown.Escape (escapeHref, escapeHtml)
import Sitegen.Markdown.Inline (parseInlines)
import Sitegen.Markdown.Types

-- | Render a list of blocks as HTML.
renderBlocks :: [Block] -> Text
renderBlocks bs = T.concat (reverse (foldl (block False) [] bs))

-- | Render inline elements as HTML.
renderInlines :: [Inline] -> Text
renderInlines = T.concat . map inline

-- Output is accumulated as a reversed list of non-empty chunks, so that the
-- "newline unless already at line start" operation can inspect the tail.
type Out = [Text]

push :: Text -> Out -> Out
push t o = if T.null t then o else t : o

cr :: Out -> Out
cr [] = []
cr o@(c : _)
  | T.last c == '\n' = o
  | otherwise = "\n" : o

block :: Bool -> Out -> Block -> Out
block tight o b = case b of
  BQuote kids ->
    push "</blockquote>\n" . cr $ foldl (block False) (push "<blockquote>\n" (cr o)) kids
  BList ty t items ->
    let open = case ty of
          BulletList -> "<ul>\n"
          OrderedList 1 -> "<ol>\n"
          OrderedList n -> "<ol start=\"" <> T.pack (show n) <> "\">\n"
        close = case ty of
          BulletList -> "</ul>\n"
          OrderedList _ -> "</ol>\n"
        item acc kids = push "</li>\n" (foldl (block t) (push "<li>" (cr acc)) kids)
     in push close (foldl item (push open (cr o)) items)
  BParagraph raw
    | tight -> push (renderInlines (parseInlines raw)) o
    | otherwise -> push "</p>\n" (push (renderInlines (parseInlines raw)) (push "<p>" (cr o)))
  BHeading k raw ->
    let tag = "h" <> T.pack (show k)
     in push ("</" <> tag <> ">\n") (push (renderInlines (parseInlines raw)) (push ("<" <> tag <> ">") (cr o)))
  BCode info lit ->
    let lang = T.takeWhile (\c -> not (c `elem` (" \t\n\v\f\r" :: String))) info
        cls
          | T.null info = ""
          | "language-" `T.isPrefixOf` lang = " class=\"" <> escapeHtml lang <> "\""
          | otherwise = " class=\"language-" <> escapeHtml lang <> "\""
     in push "</code></pre>\n" (push (escapeHtml lit) (push ("<pre><code" <> cls <> ">") (cr o)))
  BThematicBreak -> push "<hr />\n" (cr o)

inline :: Inline -> Text
inline i = case i of
  Str t -> escapeHtml t
  SoftBreak -> "\n"
  HardBreak -> "<br />\n"
  Code t -> "<code>" <> escapeHtml t <> "</code>"
  Emph kids -> "<em>" <> renderInlines kids <> "</em>"
  Strong kids -> "<strong>" <> renderInlines kids <> "</strong>"
  Link dest title kids ->
    "<a href=\"" <> escapeHref dest <> "\"" <> titleAttr title <> ">" <> renderInlines kids <> "</a>"
  Image dest title kids ->
    "<img src=\"" <> escapeHref dest <> "\" alt=\"" <> altText kids <> "\"" <> titleAttr title <> " />"
  where
    titleAttr = maybe "" (\t -> " title=\"" <> escapeHtml t <> "\"")

-- | The plain text of an image description.
altText :: [Inline] -> Text
altText = T.concat . map go
  where
    go i = case i of
      Str t -> escapeHtml t
      Code t -> escapeHtml t
      SoftBreak -> " "
      HardBreak -> " "
      Emph k -> altText k
      Strong k -> altText k
      Link _ _ k -> altText k
      Image _ _ k -> altText k
