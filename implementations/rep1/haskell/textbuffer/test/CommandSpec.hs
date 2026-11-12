module CommandSpec (spec) where

import qualified Data.ByteString.Char8 as B
import Test.Hspec

import TextBuffer

parse :: String -> Either String Command
parse = parseCommand . B.pack

spec :: Spec
spec = do
  it "decodes insert escapes" $ do
    parse "insert a\\nb\\\\c" `shouldBe` Right (Insert (B.pack "a\nb\\c"))
    parse "insert  x " `shouldBe` Right (Insert (B.pack " x "))
  it "rejects a dangling backslash" $
    parse "insert a\\" `shouldSatisfy` either (const True) (const False)
  it "parses moves" $ do
    parse "move left" `shouldBe` Right (Move MoveLeft False)
    parse "move end select" `shouldBe` Right (Move MoveEnd True)
  it "parses positions" $ do
    parse "goto 3 1000000000" `shouldBe` Right (Goto 3 1000000000)
    parse "add-cursor 0 0" `shouldBe` Right (AddCursor 0 0)
  it "parses the argument-free commands" $
    mapM parse ["delete", "delete-forward", "clear-cursors", "undo", "redo", "print"]
      `shouldBe` Right [Delete, DeleteForward, ClearCursors, Undo, Redo, Print]
  it "rejects unknown commands" $ do
    parse "jump" `shouldSatisfy` either (const True) (const False)
    parse "move sideways" `shouldSatisfy` either (const True) (const False)
    parse "goto 1" `shouldSatisfy` either (const True) (const False)
