{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Commonmark.Html
-- Description : Phase 3: rendering a document tree as HTML.
--
-- The renderer reproduces the exact output format of @cmark@: block elements
-- each start on a fresh line, tight list items omit their paragraph tags,
-- and so on.
module Commonmark.Html
  ( renderHtml
  , renderInlines
  , escapeHtml
  , escapeHref
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.ByteString.Builder
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Unsafe as BU
import Data.Word (Word8)

import Commonmark.Types

-- | Render a document as HTML.
renderHtml :: [Block [Inline]] -> Builder
renderHtml = fst . renderBlocks False

-- | Render a sequence of inline nodes as HTML (without any surrounding block tags).
renderInlines :: [Inline] -> Builder
renderInlines = foldMap renderInline

-- | Replace each byte satisfying the predicate with the builder, copying the
-- runs in between untouched.
escapeBy :: (Word8 -> Bool) -> (Word8 -> Builder) -> ByteString -> Builder
escapeBy needs repl = go
  where
    go s = case B.findIndex needs s of
      Nothing -> byteString s
      Just i -> byteString (B.take i s) <> repl (BU.unsafeIndex s i) <> go (B.drop (i + 1) s)

-- | HTML-escape @&@, @<@, @>@ and @"@.
escapeHtml :: ByteString -> Builder
escapeHtml = escapeBy (\w -> w == 38 || w == 60 || w == 62 || w == 34) repl
  where
    repl 38 = "&amp;"
    repl 60 = "&lt;"
    repl 62 = "&gt;"
    repl _ = "&quot;"

-- | Prepare a link destination for use in an @href@ or @src@ attribute:
-- dangerous schemes give an empty value, everything outside the safe set is
-- percent-encoded.
escapeHref :: ByteString -> Builder
escapeHref dest
  | dangerous = mempty
  | otherwise = escapeBy (not . safe) repl dest
  where
    lower = BC.map toLowerAscii (B.take 15 dest)
    toLowerAscii ch = if ch >= 'A' && ch <= 'Z' then toEnum (fromEnum ch + 32) else ch
    startsWith p = p `B.isPrefixOf` lower
    dangerous =
      (startsWith "javascript:" || startsWith "vbscript:" || startsWith "file:" || startsWith "data:")
        && not (any startsWith ["data:image/png", "data:image/gif", "data:image/jpeg", "data:image/webp"])
    safe w =
      (w >= 65 && w <= 90)
        || (w >= 97 && w <= 122)
        || (w >= 48 && w <= 57)
        || B.elem w "-_.~!#$%()*+,/:;=?@"
    repl 38 = "&amp;"
    repl 39 = "&#x27;"
    repl w = word8 37 <> word8 (hex (w `div` 16)) <> word8 (hex (w `mod` 16))
    hex d = if d < 10 then 48 + d else 55 + d

renderInline :: Inline -> Builder
renderInline inl = case inl of
  Text t -> escapeHtml t
  SoftBreak -> "\n"
  LineBreak -> "<br />\n"
  Code c -> "<code>" <> escapeHtml c <> "</code>"
  Emph xs -> "<em>" <> renderInlines xs <> "</em>"
  Strong xs -> "<strong>" <> renderInlines xs <> "</strong>"
  Link d t xs -> "<a href=\"" <> escapeHref d <> "\"" <> titleAttr t <> ">" <> renderInlines xs <> "</a>"
  Image d t xs ->
    "<img src=\"" <> escapeHref d <> "\" alt=\"" <> foldMap altText xs <> "\"" <> titleAttr t <> " />"

titleAttr :: Maybe ByteString -> Builder
titleAttr Nothing = mempty
titleAttr (Just t) = " title=\"" <> escapeHtml t <> "\""

-- | The plain-text rendering of image descriptions.
altText :: Inline -> Builder
altText inl = case inl of
  Text t -> escapeHtml t
  Code c -> escapeHtml c
  SoftBreak -> " "
  LineBreak -> " "
  Emph xs -> foldMap altText xs
  Strong xs -> foldMap altText xs
  Link _ _ xs -> foldMap altText xs
  Image _ _ xs -> foldMap altText xs

-- | Render blocks.  The flag says whether a newline is needed before the
-- next block (the output so far is non-empty and does not end in a newline);
-- the result carries the same flag for the output after these blocks.
renderBlocks :: Bool -> [Block [Inline]] -> (Builder, Bool)
renderBlocks nl [] = (mempty, nl)
renderBlocks nl (b : bs) =
  let (x, nl1) = renderBlock nl b
      (y, nl2) = renderBlocks nl1 bs
   in (x <> y, nl2)

cr :: Bool -> Builder
cr True = "\n"
cr False = mempty

renderBlock :: Bool -> Block [Inline] -> (Builder, Bool)
renderBlock nl blk = case blk of
  Paragraph xs -> (cr nl <> "<p>" <> renderInlines xs <> "</p>\n", False)
  Heading k xs ->
    let tag = "h" <> intDec k
     in (cr nl <> "<" <> tag <> ">" <> renderInlines xs <> "</" <> tag <> ">\n", False)
  ThematicBreak -> (cr nl <> "<hr />\n", False)
  CodeBlock info code ->
    let cls = case BC.words info of
          [] -> mempty
          (w : _) ->
            " class=\"" <> (if "language-" `B.isPrefixOf` w then mempty else "language-") <> escapeHtml w <> "\""
     in (cr nl <> "<pre><code" <> cls <> ">" <> escapeHtml code <> "</code></pre>\n", False)
  BlockQuote bs ->
    let (inner, nl1) = renderBlocks False bs
     in (cr nl <> "<blockquote>\n" <> inner <> cr nl1 <> "</blockquote>\n", False)
  List ty tight items ->
    let open = case ty of
          BulletList -> "<ul>\n"
          OrderedList 1 -> "<ol>\n"
          OrderedList k -> "<ol start=\"" <> intDec k <> "\">\n"
        close = case ty of BulletList -> "</ul>\n"; _ -> "</ol>\n"
     in (cr nl <> open <> renderItems tight items <> close, False)

renderItems :: Bool -> [[Block [Inline]]] -> Builder
renderItems _ [] = mempty
renderItems tight (it : rest) = item <> renderItems tight rest
  where
    item = "<li>" <> body <> "</li>\n"
    body = fst (renderItemBlocks True it)
    -- the output so far ends with "<li>", so a newline is needed before a block
    renderItemBlocks nl [] = (mempty, nl)
    renderItemBlocks nl (b : bs) =
      let (x, nl1) = case b of
            Paragraph xs | tight -> (renderInlines xs, True)
            _ -> renderBlock nl b
          (y, nl2) = renderItemBlocks nl1 bs
       in (x <> y, nl2)
