{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Test.Hspec
import Test.QuickCheck

import Commonmark
import Commonmark.Html (escapeHref, escapeHtml)
import Commonmark.Internal.Text (decodeEntities, matchEntity, unescapeBackslashes)
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import Examples

html :: B.ByteString -> B.ByteString
html = commonmarkToHtml

inlines :: B.ByteString -> [Inline]
inlines = parseInlines

main :: IO ()
main = hspec $ do
  describe "CommonMark specification examples" $
    mapM_
      ( \e ->
          it ("example " ++ show (exNumber e) ++ " (" ++ exSection e ++ ")") $
            html (BC.pack (exMarkdown e)) `shouldBe` BC.pack (exHtml e)
      )
      examples

  describe "block structure" $ do
    it "empty document" $ html "" `shouldBe` ""
    it "heading and paragraph" $
      parseBlocks "# Hi\n\nfoo\nbar\n" `shouldBe` [Heading 1 "Hi", Paragraph "foo\nbar\n"]
    it "setext heading takes the whole paragraph" $
      parseBlocks "a\nb\n---\n" `shouldBe` [Heading 2 "a\nb\n"]
    it "block quote followed by thematic break" $
      parseBlocks "> foo\n---\n" `shouldBe` [BlockQuote [Paragraph "foo\n"], ThematicBreak]
    it "tight and loose lists" $ do
      parseBlocks "- a\n- b\n" `shouldBe` [List BulletList True [[Paragraph "a\n"], [Paragraph "b\n"]]]
      parseBlocks "- a\n\n- b\n" `shouldBe` [List BulletList False [[Paragraph "a\n"], [Paragraph "b\n"]]]
    it "ordered list start number" $
      parseBlocks "003. x\n" `shouldBe` [List (OrderedList 3) True [[Paragraph "x\n"]]]
    it "fenced code info string" $
      parseBlocks "```  rust &amp; \\*\ncode\n```\n" `shouldBe` [CodeBlock "rust & *" "code\n"]
    it "indented code drops trailing blank lines" $
      parseBlocks "    a\n\n\n" `shouldBe` [CodeBlock "" "a\n"]
    it "an unclosed fence runs to the end of the document" $
      parseBlocks "```\na\n\n" `shouldBe` [CodeBlock "" "a\n\n"]
    it "tabs count as columns of 4" $
      html "-\tfoo\n" `shouldBe` "<ul>\n<li>foo</li>\n</ul>\n"
    it "handles input without trailing newline" $ html "foo" `shouldBe` "<p>foo</p>\n"
    it "survives 300 levels of nesting" $
      B.length (html (B.concat (replicate 300 "> ") <> "x\n")) `shouldSatisfy` (> 300)

  describe "inline structure" $ do
    it "emphasis and strong" $
      inlines "*a* **b**" `shouldBe` [Emph [Text "a"], Text " ", Strong [Text "b"]]
    it "rule of three" $
      inlines "*foo**bar**baz*"
        `shouldBe` [Emph [Text "foo", Strong [Text "bar"], Text "baz"]]
    it "intraword underscores do not emphasise" $ inlines "a_b_" `shouldBe` [Text "a_b_"]
    it "code spans strip one surrounding space" $ inlines "`` ` ``" `shouldBe` [Code "`"]
    it "unmatched backticks are text" $ inlines "``a`" `shouldBe` [Text "``a`"]
    it "hard and soft breaks" $
      inlines "a  \nb\nc\\\nd" `shouldBe` [Text "a", LineBreak, Text "b", SoftBreak, Text "c", LineBreak, Text "d"]
    it "inline link with title" $
      inlines "[a](/u \"t\")" `shouldBe` [Link "/u" (Just "t") [Text "a"]]
    it "links may not contain links (single flag)" $
      html "[x [a](/b) y](/d)\n" `shouldBe` "<p>[x <a href=\"/b\">a</a> y](/d)</p>\n"
    it "the link_closed flag is cleared by a later [" $
      html "[x [a](/b) ![i [q] j](/k) y](/d)\n"
        `shouldBe` "<p><a href=\"/d\">x <a href=\"/b\">a</a> <img src=\"/k\" alt=\"i [q] j\" /> y</a></p>\n"
    it "images keep alt text only" $
      html "![a *b* `c`](/i.png)\n" `shouldBe` "<p><img src=\"/i.png\" alt=\"a b c\" /></p>\n"
    it "autolinks" $ do
      inlines "<http://a.b/?x=1&amp;y>" `shouldBe` [Link "http://a.b/?x=1&y" Nothing [Text "http://a.b/?x=1&y"]]
      inlines "<me@x.org>" `shouldBe` [Link "mailto:me@x.org" Nothing [Text "me@x.org"]]
      inlines "<a b>" `shouldBe` [Text "<a b>"]
    it "numeric entities" $ do
      inlines "&#65;&#x42;&#0;" `shouldBe` [Text "AB\239\191\189"]
      inlines "&#12345678;" `shouldBe` [Text "&#12345678;"]
      inlines "&foo; &amp" `shouldBe` [Text "&foo; &amp"]
    it "backslash escapes" $ inlines "\\*a\\*" `shouldBe` [Text "*a*"]
    it "empty content" $ inlines "  \n" `shouldBe` []

  describe "helpers" $ do
    it "matchEntity" $ do
      matchEntity "amp;" 0 `shouldBe` Just ("&", 4)
      matchEntity "#x1F600;" 0 `shouldBe` Just ("\240\159\152\128", 8)
      matchEntity "#x;" 0 `shouldBe` Nothing
    it "decodeEntities / unescapeBackslashes" $ do
      decodeEntities "a &lt; b &quot;&gt;" `shouldBe` "a < b \">"
      unescapeBackslashes "\\&amp; \\\\ \\a" `shouldBe` "&amp; \\ \\a"
    it "escapeHtml" $ render (escapeHtml "<a href=\"x\">&</a>") `shouldBe` "&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;"
    it "escapeHref" $ do
      render (escapeHref "/a b?c=d&e'") `shouldBe` "/a%20b?c=d&amp;e&#x27;"
      render (escapeHref "JavaScript:alert(1)") `shouldBe` ""
      render (escapeHref "data:image/png;base64,xx") `shouldBe` "data:image/png;base64,xx"
      render (escapeHref "/\195\188") `shouldBe` "/%C3%BC"

  describe "properties" $ do
    it "never crashes and always ends output with a newline (or is empty)" $
      property $ forAll markdownish $ \s ->
        let out = html (BC.pack s) in B.null out || BC.last out == '\n'
    it "plain alphanumeric words are wrapped in a paragraph" $
      property $ forAll (listOf1 (elements ['a' .. 'z'])) $ \w ->
        html (BC.pack w) === BC.pack ("<p>" ++ w ++ "</p>\n")
    it "inline parsing never yields empty or adjacent text nodes" $
      property $ forAll markdownish $ \s -> wellFormed (inlines (BC.pack s))
  where
    render = BL.toStrict . BB.toLazyByteString
    wellFormed xs = and (zipWith (\a b -> not (isText a && isText b)) xs (drop 1 xs)) && all ok xs
    isText (Text _) = True
    isText _ = False
    ok (Text t) = not (B.null t)
    ok (Emph xs) = wellFormed xs
    ok (Strong xs) = wellFormed xs
    ok (Link _ _ xs) = wellFormed xs
    ok (Image _ _ xs) = wellFormed xs
    ok _ = True

-- | Random text built from Markdown-significant fragments.
markdownish :: Gen String
markdownish = concat <$> listOf (frequency [(3, frag), (2, word)])
  where
    word = listOf1 (elements "abcxyz 09")
    frag =
      elements
        [ "*", "**", "_", "__", "`", "``", "[", "]", "(", ")", "![", "](/u)", "\n", "\n\n", "> ", "- ", "1. "
        , "# ", "    ", "\t", "---", "===", "```\n", "~~~", "\\", "&amp;", "&#65;", "<http://a.b>", "<", "  \n"
        ]
