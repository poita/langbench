module DocumentSpec (spec) where

import qualified Data.ByteString.Char8 as B
import Test.Hspec

import TextBuffer (Pos (..))
import TextBuffer.Document
import TextBuffer.Position (advance)

doc :: Document
doc = fromText (B.pack "abc\n\ndefg")

spec :: Spec
spec = do
  it "has one empty line when built from nothing" $
    toLines (fromLines []) `shouldBe` [B.empty]
  it "round-trips text" $ toText doc `shouldBe` B.pack "abc\n\ndefg"
  it "clamps line first, then column" $ do
    clampPos doc (Pos 99 99) `shouldBe` Pos 2 4
    clampPos doc (Pos 1 7) `shouldBe` Pos 1 0
    clampPos doc (Pos 0 2) `shouldBe` Pos 0 2
  it "slices within and across lines" $ do
    slice (Pos 0 1) (Pos 0 3) doc `shouldBe` B.pack "bc"
    slice (Pos 0 2) (Pos 2 1) doc `shouldBe` B.pack "c\n\nd"
  it "replaces within a line" $
    toText (replace (Pos 0 1) (Pos 0 2) (B.pack "XY") doc)
      `shouldBe` B.pack "aXYc\n\ndefg"
  it "replaces across lines, inserting newlines" $
    toText (replace (Pos 0 1) (Pos 2 2) (B.pack "1\n2\n3") doc)
      `shouldBe` B.pack "a1\n2\n3fg"
  it "joins lines on deletion of a newline" $
    toText (replace (Pos 0 3) (Pos 1 0) B.empty doc) `shouldBe` B.pack "abc\ndefg"
  it "advances positions over inserted text" $ do
    advance (Pos 3 4) (B.pack "ab") `shouldBe` Pos 3 6
    advance (Pos 3 4) (B.pack "a\nbcd\ne") `shouldBe` Pos 5 1
    advance (Pos 3 4) (B.pack "x\n") `shouldBe` Pos 4 0
