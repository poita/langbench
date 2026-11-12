module Typeset.ParserSpec (spec) where

import Test.Hspec

import Typeset.Error
import Typeset.Parser
import Typeset.Syntax

failing :: [String] -> Maybe (Int, Int, ErrorCode)
failing ls = case parseDocument (unlines ls) of
  Left e -> Just (errLine e, errCol e, errCode e)
  Right _ -> Nothing

blocks :: [String] -> [Block]
blocks ls = case parseDocument (unlines ls) of
  Right d -> docBlocks d
  Left e -> error (show e)

spec :: Spec
spec = do
  describe "block structure" $ do
    it "parses paragraphs, continuation lines and headings" $ do
      case blocks ["@h1 Title", "text one", "  continues", "", "second"] of
        [BHeading 1 False _, BPara p1, BPara p2] -> do
          plainText p1 `shouldBe` "text one continues"
          plainText p2 `shouldBe` "second"
        other -> expectationFailure (show other)
    it "keeps a heading's own line only" $
      length (blocks ["@h2* Head", "body"]) `shouldBe` 2
    it "numbers footnotes in source order" $
      case blocks ["a{n|one} b{n|two}", "", "c{n|three}"] of
        [BPara p, BPara q] -> do
          map fst (footnotesOf p) `shouldBe` [1, 2]
          map fst (footnotesOf q) `shouldBe` [3]
        other -> expectationFailure (show other)
    it "builds lists with items and nested blocks" $
      case blocks ["@ul", "@li one", "@li two", "@ol start=3", "@li x", "@end", "@end"] of
        [BList Unordered [ListItem _ [], ListItem _ [BList (Ordered 3) [_]]]] -> return ()
        other -> expectationFailure (show other)
    it "reads tables, figures and pre blocks" $
      case blocks [ "@table cols=2 align=lr", "a | b", "@hrule", "c | d", "@end"
                  , "@fig height=10pt", "cap", "", "more", "@end"
                  , "@pre", "  x  ", "@end" ] of
        [BTable 2 [ColLeft, ColRight] [TRow [_, _], THRule, TRow _], BFig 10000 Nothing cap, BPre ["  x"]] ->
          plainText cap `shouldBe` "cap more"
        other -> expectationFailure (show other)
    it "reads the @doc metadata and @toc" $
      case parseDocument "@doc\ntitle = A Title\nauthor=Me\n@end\n@toc title=\"My Contents\"\ntext\n" of
        Right d -> do
          metaTitle (docMeta d) `shouldBe` "A Title"
          metaAuthor (docMeta d) `shouldBe` "Me"
          docToc d `shouldBe` Just (Just "My Contents")
        Left e -> expectationFailure (show e)
    it "accepts an empty document" $
      fmap docBlocks (parseDocument "") `shouldSatisfy` either (const False) null
  describe "plain text of a heading" $
    it "drops styles and discretionary points, collapses spaces" $
      case blocks ["@h1  {b|Intro}\\-duc~tion   here "] of
        [BHeading _ _ t] -> plainText t `shouldBe` "Introduc tion here"
        other -> expectationFailure (show other)
  describe "errors" $ do
    it "reports inline errors" $ do
      failing ["@h1 Title", "{z|oops}"] `shouldBe` Just (2, 1, UnknownInline)
      failing ["a {b|c"] `shouldBe` Just (1, 3, UnclosedInline)
      failing ["{b|{i|x}"] `shouldBe` Just (1, 1, UnclosedInline)
      failing ["a } b"] `shouldBe` Just (1, 3, StrayBrace)
      failing ["abc\\"] `shouldBe` Just (1, 4, BadEscape)
      failing ["abc\\q"] `shouldBe` Just (1, 4, BadEscape)
      failing ["{n|a{n|b}}"] `shouldBe` Just (1, 5, NestedFootnote)
      failing ["@h1 a{n|b}"] `shouldBe` Just (1, 6, FootnoteNotAllowed)
    it "lets a trailing backslash escape the joining space" $
      failing ["ghi\\", "  jkl"] `shouldBe` Nothing
    it "reports structural errors" $ do
      failing ["@frob"] `shouldBe` Just (1, 1, UnknownBlock)
      failing ["@h1x y"] `shouldBe` Just (1, 1, UnknownBlock)
      failing ["@end"] `shouldBe` Just (1, 1, UnexpectedEnd)
      failing ["@q", "text"] `shouldBe` Just (3, 1, MissingEnd)
      failing ["@hrule"] `shouldBe` Just (1, 1, BlockNotAllowed)
      failing ["@li x"] `shouldBe` Just (1, 1, BlockNotAllowed)
      failing ["@toc", "@toc"] `shouldBe` Just (2, 1, DuplicateToc)
      failing ["text", "@toc"] `shouldBe` Just (2, 1, BlockNotAllowed)
      failing ["@ul", "text"] `shouldBe` Just (2, 1, TextNotAllowed)
      failing ["@ul", "@q"] `shouldBe` Just (2, 1, BlockNotAllowed)
    it "reports attribute errors in the documented order" $ do
      failing ["@table align=xyz"] `shouldBe` Just (1, 1, MissingAttribute)
      failing ["@table cols=0 foo=1"] `shouldBe` Just (1, 15, BadAttribute)
      failing ["@table cols=0"] `shouldBe` Just (1, 13, BadAttributeValue)
      failing ["@table cols=2 align=l"] `shouldBe` Just (1, 21, BadAttributeValue)
      failing ["@table cols=1", "@vspace height=abc", "@end"] `shouldBe` Just (2, 1, BlockNotAllowed)
      failing ["@table cols=1", "@vspace", "@end"] `shouldBe` Just (2, 1, MissingAttribute)
      failing ["@end foo=1"] `shouldBe` Just (1, 6, BadAttribute)
      failing ["@vspace height=\"10pt\"x"] `shouldBe` Just (1, 16, BadAttributeValue)
      failing ["@vspace height="] `shouldBe` Just (1, 16, BadAttributeValue)
    it "counts table cells before reading their content" $ do
      failing ["@table cols=2", "{b|x} | y", "@end"] `shouldBe` Just (2, 1, CellCount)
      failing ["@table cols=3", "{b|x} | y", "@end"] `shouldBe` Just (2, 1, UnknownInline)
    it "checks @doc lines" $ do
      failing ["@doc", "nonsense", "@end"] `shouldBe` Just (2, 1, BadSyntax)
      failing ["@doc", "colour = red", "@end"] `shouldBe` Just (2, 1, UnknownMeta)
      failing ["@doc", "title = a", "title = b", "@end"] `shouldBe` Just (3, 1, DuplicateMeta)
      failing ["@doc", "@q", "@end"] `shouldBe` Just (2, 1, BlockNotAllowed)
