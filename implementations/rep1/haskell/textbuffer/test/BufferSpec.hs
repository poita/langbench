module BufferSpec (spec) where

import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as BL
import Test.Hspec

import TextBuffer
import qualified TextBuffer.Document as Doc

-- | Run commands (one per string) on a buffer made of the given lines.
run :: [String] -> [String] -> Buffer
run ls cmds = foldl (flip execute) (fromLines (map B.pack ls)) (map cmd cmds)
  where cmd = either error id . parseCommand . B.pack

linesOf :: Buffer -> [String]
linesOf = map B.unpack . Doc.toLines . document

headsOf :: Buffer -> [(Int, Int)]
headsOf = map (\c -> let Pos l k = curHead c in (l, k)) . cursors

spec :: Spec
spec = do
  describe "editing" $ do
    it "inserts and splits lines" $ do
      let b = run ["ab"] ["move right", "insert x\\ny"]
      linesOf b `shouldBe` ["ax", "yb"]
      headsOf b `shouldBe` [(1, 1)]
    it "backspace joins lines" $ do
      let b = run ["ab", "cd"] ["goto 1 0", "delete"]
      linesOf b `shouldBe` ["abcd"]
      headsOf b `shouldBe` [(0, 2)]
    it "does nothing at the document edges" $ do
      let b = run ["ab"] ["delete", "move end", "delete-forward"]
      linesOf b `shouldBe` ["ab"]
      canUndo b `shouldBe` False
    it "replaces a selection on insert" $
      linesOf (run ["hello"] ["move right select", "move right select", "insert J"])
        `shouldBe` ["Jllo"]
    it "edits at every cursor, shifting later ones" $ do
      let b = run ["aa", "bb"] ["add-cursor 0 1", "add-cursor 1 1", "insert -"]
      linesOf b `shouldBe` ["-a-a", "b-b"]
      headsOf b `shouldBe` [(0, 1), (0, 3), (1, 2)]
    it "adjacent backspaces merge cursors" $ do
      let b = run ["abcdef"] ["goto 0 3", "add-cursor 0 4", "delete"]
      linesOf b `shouldBe` ["abef"]
      headsOf b `shouldBe` [(0, 2)]
  describe "movement" $ do
    it "remembers the goal column" $
      headsOf (run ["abcdef", "a", "abcdef"] ["goto 0 4", "move down", "move down"])
        `shouldBe` [(2, 4)]
    it "up on the first line goes to the start" $
      headsOf (run ["abc"] ["move end", "move up"]) `shouldBe` [(0, 0)]
    it "collapses selections on left/right" $ do
      let sel2 = ["move right select", "move right select"]
      headsOf (run ["abcd"] (sel2 ++ ["move left"])) `shouldBe` [(0, 0)]
      headsOf (run ["abcd"] (sel2 ++ ["move right"])) `shouldBe` [(0, 2)]
    it "clamps goto and add-cursor" $ do
      headsOf (run ["ab", "c"] ["goto 99 99"]) `shouldBe` [(1, 1)]
      headsOf (run ["ab", "c"] ["add-cursor 0 99"]) `shouldBe` [(0, 0), (0, 2)]
    it "clear-cursors keeps the primary" $
      headsOf (run ["ab", "cd"] ["goto 1 1", "add-cursor 0 0", "clear-cursors"])
        `shouldBe` [(1, 1)]
  describe "history" $ do
    it "undo restores document and cursors; redo reapplies" $ do
      let b0 = run ["ab", "cd"] ["add-cursor 1 1", "move end select"]
          b1 = execute (Insert (B.pack "X")) b0
          b2 = execute Undo b1
          b3 = execute Redo b2
      linesOf b2 `shouldBe` ["ab", "cd"]
      cursors b2 `shouldBe` map (\c -> c { curGoal = posCol (curHead c) }) (cursors b0)
      linesOf b3 `shouldBe` linesOf b1
      cursors b3 `shouldBe` cursors b1
    it "a new edit clears the redo stack" $ do
      let b = run ["a"] ["insert x", "undo", "insert y"]
      canRedo b `shouldBe` False
    it "a no-op edit leaves the redo stack alone" $ do
      let b = run ["a"] ["insert x", "undo", "delete"]
      canRedo b `shouldBe` True
    it "undo on an empty history changes nothing" $
      linesOf (run ["a"] ["undo", "redo"]) `shouldBe` ["a"]
  describe "scripts" $ do
    it "prints lines, cursor positions and a separator" $
      output "2\nab\ncd\nmove end\nprint\n" `shouldBe` "ab\ncd\ncursor 0 2\n--\n"
    it "prints nothing without a print command" $
      output "1\nab\nmove end\n" `shouldBe` ""
    it "treats initial lines verbatim, even if they look like commands" $
      output "2\nprint\n  x \nprint" `shouldBe` "print\n  x \ncursor 0 0\n--\n"
    it "starts from one empty line when N is 0" $
      output "0\ninsert a\nprint\n" `shouldBe` "a\ncursor 0 1\n--\n"
    it "reports a bad command with its line number" $
      either id (const "") (runScript (B.pack "1\nab\nbogus\n"))
        `shouldBe` "line 3: unrecognised command: bogus"
  where
    output = either error (BL.unpack . BB.toLazyByteString) . runScript . B.pack
