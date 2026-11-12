module Typeset.SettingsSpec (spec) where

import qualified Data.Map.Strict as M
import Test.Hspec

import Typeset.Error
import Typeset.Settings
import Typeset.Types

failing :: String -> Maybe (Int, Int, ErrorCode)
failing txt = case parseSettings txt of
  Left e -> Just (errLine e, errCol e, errCode e)
  Right _ -> Nothing

-- | Parse settings that are known to be valid.
valid :: Either Error Settings -> Settings
valid = either (error . show) id

spec :: Spec
spec = do
  describe "parseLength" $ do
    it "reads units and fractions" $ do
      map parseLength ["2.5pt", "0.5pt", "1.5mm", "-6pt", "734", "1in", "1pc", "2cm"]
        `shouldBe` map Just [2500, 500, 4252, -6000, 734, 72000, 12000, 56700]
    it "rejects malformed lengths" $
      map parseLength ["", "+1pt", "1.2345pt", ".5pt", "1.pt", "1px", "1 pt", "--1", "1.5.2"]
        `shouldBe` replicate 9 Nothing
  describe "parseInteger" $
    it "accepts an optional minus sign only" $
      map parseInteger ["12", "-3", "+3", "", "1.0"] `shouldBe` [Just 12, Just (-3), Nothing, Nothing, Nothing]
  describe "scanText" $ do
    it "reads literals, escapes and placeholders" $
      scanText "a\\{b {page}/{pages}" `shouldBe` Right [PLit "a{b ", PHold PhPage, PLit "/", PHold PhPages]
    it "reports the offending character" $ do
      scanText "\\{page}" `shouldBe` Left (StrayBrace, 6)
      scanText "}\\q" `shouldBe` Left (StrayBrace, 0)
      scanText "{pa\\ge}" `shouldBe` Left (UnknownPlaceholder, 0)
      scanText "x{page" `shouldBe` Left (UnknownPlaceholder, 1)
      scanText "ab\\" `shouldBe` Left (BadEscape, 2)
  describe "parseSettings" $ do
    it "accepts the empty file and comments" $ do
      failing "" `shouldBe` Nothing
      failing "# only a comment\n\n   \t\n" `shouldBe` Nothing
    it "resolves derived defaults" $ do
      let s = valid (parseSettings "page-height = 100pt\nmargin-top = 10pt\nmargin-bottom = 10pt\n")
      footerBaseline s `shouldBe` 64000
      footnoteMaxHeight s `shouldBe` 40000
    it "lets -even slots fall back to their plain key" $ do
      let s = valid (parseSettings "header-left = L{page}\nfooter-left-even = E\n")
      slotTemplate s "header-left" True `shouldBe` [PLit "L", PHold PhPage]
      slotTemplate s "footer-left" True `shouldBe` [PLit "E"]
      slotTemplate s "footer-left" False `shouldBe` []
    it "reads every type of value" $ do
      let s = valid (parseSettings "align = center\nbody-font = mono\nhyphenate = off\ntolerance = 200\nh2-size = 15pt\n")
      bodyAlign s `shouldBe` AlignCenter
      bodyFont s `shouldBe` Mono
      hyphenate s `shouldBe` False
      tolerance s `shouldBe` 200
      headingSize s 2 `shouldBe` 15000
      headingSize s 1 `shouldBe` 20000
    it "reports errors at the right place" $ do
      failing "page-width 200pt" `shouldBe` Just (1, 1, BadSyntax)
      failing "  tolerence = 3" `shouldBe` Just (1, 3, UnknownSetting)
      failing "align = left\nalign = right" `shouldBe` Just (2, 1, DuplicateSetting)
      failing "margin-top =" `shouldBe` Just (1, 13, BadLength)
      failing "margin-top =  20px" `shouldBe` Just (1, 15, BadLength)
      failing "hyphenate = yes" `shouldBe` Just (1, 13, BadBoolean)
      failing "align = middle" `shouldBe` Just (1, 9, BadEnum)
      failing "body-font = fancy" `shouldBe` Just (1, 13, UnknownFont)
      failing "hyphen-patterns = french" `shouldBe` Just (1, 19, UnknownPatterns)
      failing "margin-left = -1pt" `shouldBe` Just (1, 15, BadValue)
      failing "toc-leader = . ." `shouldBe` Just (1, 14, BadValue)
      failing "toc-title = {title}" `shouldBe` Just (1, 13, BadValue)
      failing "footer-right = {page" `shouldBe` Just (1, 16, UnknownPlaceholder)
    it "reports a too small body at the last geometry key" $ do
      failing "margin-bottom = 50pt\npage-height = 120pt\nmargin-top = 40pt\nalign = left\n"
        `shouldBe` Just (3, 14, BadValue)
    it "allows tabs around the equals sign and keeps # in values" $ do
      failing "align\t=\tleft" `shouldBe` Nothing
      failing "toc-title = a # b" `shouldBe` Nothing
  describe "defaults" $
    it "start with six empty plain header/footer slots" $
      M.elems (hfTexts defaultSettings) `shouldBe` replicate 6 []
