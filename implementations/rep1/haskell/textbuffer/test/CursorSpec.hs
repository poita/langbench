module CursorSpec (spec) where

import Test.Hspec

import TextBuffer
import TextBuffer.Cursor (isBackward, normalize, pointCursor)

sel :: Bool -> (Int, Int) -> (Int, Int) -> Cursor
sel primary (hl, hc) (al, ac) = Cursor (Pos hl hc) (Just (Pos al ac)) primary hc

pt :: Bool -> Int -> Int -> Cursor
pt primary l c = pointCursor primary (Pos l c)

heads :: [Cursor] -> [(Int, Int)]
heads = map (\c -> let Pos l k = curHead c in (l, k))

spec :: Spec
spec = do
  it "orders ranges by start" $
    heads (normalize [pt False 2 0, pt True 0 5, pt False 1 1])
      `shouldBe` [(0, 5), (1, 1), (2, 0)]
  it "merges equal points, keeping the primary flag" $ do
    let r = normalize [pt False 1 1, pt True 1 1]
    length r `shouldBe` 1
    map curPrimary r `shouldBe` [True]
  it "merges a point inside a selection, keeping the selection" $ do
    let r = normalize [sel True (0, 1) (0, 5), pt False 0 3]
    r `shouldBe` [sel True (0, 1) (0, 5)]
    map isBackward r `shouldBe` [True]
  it "does not merge touching selections" $
    length (normalize [sel True (0, 3) (0, 1), sel False (0, 6) (0, 3)])
      `shouldBe` 2
  it "merges overlapping selections into their union" $ do
    let r = normalize [sel True (0, 4) (0, 1), sel False (0, 7) (0, 3)]
    map rangeStart r `shouldBe` [Pos 0 1]
    map rangeEnd r `shouldBe` [Pos 0 7]
  it "merges a point touching a selection edge" $
    length (normalize [sel True (0, 3) (0, 1), pt False 0 3]) `shouldBe` 1
  it "keeps the goal column of the first of two equal cursors" $ do
    let a = (pt False 1 1) { curGoal = 7 }
        b = (pt True 1 1) { curGoal = 9 }
    map curGoal (normalize [a, b]) `shouldBe` [7]
