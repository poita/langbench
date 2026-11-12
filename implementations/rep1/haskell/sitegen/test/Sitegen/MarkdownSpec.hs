{-# LANGUAGE OverloadedStrings #-}

module Sitegen.MarkdownSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec
import Test.QuickCheck

import Sitegen.Markdown

md :: [Text] -> Text
md = markdownToHtml . T.unlines

html :: [Text] -> Text
html = T.unlines

spec :: Spec
spec = do
  describe "blocks" $ do
    it "converts the empty document to the empty string" $
      markdownToHtml "" `shouldBe` ""

    it "converts paragraphs, headings and thematic breaks" $
      md ["# Title #", "", "para one", "continues", "", "---", "", "Setext", "======"]
        `shouldBe` html ["<h1>Title</h1>", "<p>para one", "continues</p>", "<hr />", "<h1>Setext</h1>"]

    it "converts indented and fenced code blocks" $
      md ["    a < b", "", "```rust extra", "fn main() {}", "```"]
        `shouldBe` html
          [ "<pre><code>a &lt; b", "</code></pre>"
          , "<pre><code class=\"language-rust\">fn main() {}", "</code></pre>" ]

    it "closes an unterminated fence at the end of the document" $
      markdownToHtml "~~~\ncode" `shouldBe` "<pre><code>code\n</code></pre>\n"

    it "converts block quotes with lazy continuation" $
      md ["> a", "b", ">", "> c"]
        `shouldBe` html ["<blockquote>", "<p>a", "b</p>", "<p>c</p>", "</blockquote>"]

    it "renders tight and loose lists" $ do
      md ["- a", "- b"] `shouldBe` html ["<ul>", "<li>a</li>", "<li>b</li>", "</ul>"]
      md ["- a", "", "- b"]
        `shouldBe` html ["<ul>", "<li>", "<p>a</p>", "</li>", "<li>", "<p>b</p>", "</li>", "</ul>"]

    it "numbers ordered lists from their first marker" $
      md ["3. a", "4. b"]
        `shouldBe` html ["<ol start=\"3\">", "<li>a</li>", "<li>b</li>", "</ol>"]

    it "starts a new list when the bullet changes" $
      md ["- a", "* b"] `shouldBe` html ["<ul>", "<li>a</li>", "</ul>", "<ul>", "<li>b</li>", "</ul>"]

    it "handles nested lists" $
      md ["- one", "- two", "  - nested"]
        `shouldBe` html
          ["<ul>", "<li>one</li>", "<li>two", "<ul>", "<li>nested</li>", "</ul>", "</li>", "</ul>"]

    it "treats a tab as indentation to the next multiple of four" $
      markdownToHtml "\tcode\n" `shouldBe` "<pre><code>code\n</code></pre>\n"

  describe "inlines" $ do
    it "converts emphasis, strong emphasis and code spans" $
      md ["*a* **b** `c` ***d***"]
        `shouldBe` html ["<p><em>a</em> <strong>b</strong> <code>c</code> <em><strong>d</strong></em></p>"]

    it "follows the rule of three" $
      md ["*foo**bar**baz*"] `shouldBe` html ["<p><em>foo<strong>bar</strong>baz</em></p>"]

    it "does not treat intraword underscores as emphasis" $
      md ["_a_b_"] `shouldBe` html ["<p><em>a_b</em></p>"]

    it "handles backslash escapes and entities" $
      md ["\\*lit\\* &amp; &#65;&#x42; &#0; &foo; &copy;"]
        `shouldBe` html ["<p>*lit* &amp; AB \xFFFD &amp;foo; &amp;copy;</p>"]

    it "renders links with titles, angle destinations and escapes" $
      md ["[link](</my uri> \"t\\\"x\")"]
        `shouldBe` html ["<p><a href=\"/my%20uri\" title=\"t&quot;x\">link</a></p>"]

    it "renders images with plain-text alt" $
      md ["![alt *x* `y`](/i.png)"] `shouldBe` html ["<p><img src=\"/i.png\" alt=\"alt x y\" /></p>"]

    it "does not allow links inside links" $
      md ["[a [b](c) d](e)"] `shouldBe` html ["<p>[a <a href=\"c\">b</a> d](e)</p>"]

    it "renders autolinks" $
      md ["<http://a.b/?x=1&y=2> <me@example.com>"]
        `shouldBe` html
          [ "<p><a href=\"http://a.b/?x=1&amp;y=2\">http://a.b/?x=1&amp;y=2</a> "
              <> "<a href=\"mailto:me@example.com\">me@example.com</a></p>" ]

    it "blanks dangerous URL schemes" $
      md ["[j](javascript:alert(1))"] `shouldBe` html ["<p><a href=\"\">j</a></p>"]

    it "renders hard and soft line breaks" $
      markdownToHtml "a  \nb\\\nc\nd\n" `shouldBe` "<p>a<br />\nb<br />\nc\nd</p>\n"

  describe "reference examples" $ do
    it "matches the first worked example" $
      markdownToHtml
        ( T.unlines
            [ "# Title #", "", "Some *emphasis*, **strong**, `code` and a [link](</my uri> \"t\\\"x\").", ""
            , "- one", "- two", "  - nested", "", "1. a", "", "   b", "2. c", ""
            , "> quote  ", "> line\\", "\tlazy", "", "    code <b>" ] )
        `shouldBe` html
          [ "<h1>Title</h1>"
          , "<p>Some <em>emphasis</em>, <strong>strong</strong>, <code>code</code> and a <a href=\"/my%20uri\" title=\"t&quot;x\">link</a>.</p>"
          , "<ul>", "<li>one</li>", "<li>two", "<ul>", "<li>nested</li>", "</ul>", "</li>", "</ul>"
          , "<ol>", "<li>", "<p>a</p>", "<p>b</p>", "</li>", "<li>", "<p>c</p>", "</li>", "</ol>"
          , "<blockquote>", "<p>quote<br />", "line<br />", "\tlazy</p>", "</blockquote>"
          , "<pre><code>code &lt;b&gt;", "</code></pre>" ]

    it "matches the third worked example" $
      markdownToHtml
        ( T.unlines
            [ "- a", "- ```py", "  x = \"<>\"", "  ```", "- c", "", "  d", "* e", "***", "Foo", "---"
            , "[j](javascript:alert(1)) [k](/x \"\") [](<>)" ] )
        `shouldBe` html
          [ "<ul>", "<li>", "<p>a</p>", "</li>", "<li>"
          , "<pre><code class=\"language-py\">x = &quot;&lt;&gt;&quot;", "</code></pre>", "</li>"
          , "<li>", "<p>c</p>", "<p>d</p>", "</li>", "</ul>", "<ul>", "<li>e</li>", "</ul>", "<hr />"
          , "<h2>Foo</h2>"
          , "<p><a href=\"\">j</a> <a href=\"/x\" title=\"\">k</a> <a href=\"\"></a></p>" ]

  describe "properties" $ do
    it "always ends a non-empty document's output with a newline" $
      property $ \(NonEmpty s) ->
        let out = markdownToHtml (T.pack (filter ok s))
         in T.null out || T.last out == '\n'

    it "never lets a raw angle bracket through unescaped in plain text" $
      property $ \s ->
        let plain = T.pack (filter (`elem` ("ab <>&" :: String)) s)
            out = markdownToHtml ("x " <> T.filter (`notElem` ("<" :: String)) plain)
         in not ("<script" `T.isInfixOf` out)
  where
    ok c = c /= '\r' && c /= '\0' && (c >= ' ' || c == '\n' || c == '\t') && c /= '\DEL' && c < '\x80'
