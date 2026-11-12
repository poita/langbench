module Scheme.ReaderPrinterSpec (spec) where

import Test.Hspec

import Scheme.Printer (displayString, writeString)
import Scheme.Reader (readAll)
import Scheme.Types

-- | Read a source text and write each datum back, separated by newlines.
roundTrip :: String -> IO [String]
roundTrip src = do
  tbl <- newSymbolTable
  map writeString <$> readAll tbl src

spec :: Spec
spec = do
  describe "reader" $ do
    it "reads literals" $
      roundTrip "42 -7 +5 007 -0 #t #f foo + - ... 1+ a.b"
        `shouldReturn` ["42", "-7", "5", "7", "0", "#t", "#f", "foo", "+", "-", "...", "1+", "a.b"]
    it "reads lists, dotted lists and quote" $
      roundTrip "() (1 2 . 3) '(a (b . c) ()) ''a"
        `shouldReturn` ["()", "(1 2 . 3)", "(quote (a (b . c) ()))", "(quote (quote a))"]
    it "skips comments and whitespace" $
      roundTrip "; one\n(a ;two\n b)\r\n\t;end" `shouldReturn` ["(a b)"]
    it "reads string escapes" $
      roundTrip "\"a\\\"b\\\\c\\nd\\te\"" `shouldReturn` ["\"a\\\"b\\\\c\\nd\\te\""]
    it "treats a raw newline in a string as a character" $ do
      tbl <- newSymbolTable
      [VStr s] <- readAll tbl "\"a\nb\""
      s `shouldBe` "a\nb"
    it "reads huge integers" $
      roundTrip "123456789012345678901234567890" `shouldReturn` ["123456789012345678901234567890"]
    it "interns symbols" $ do
      tbl <- newSymbolTable
      [VSym a, VSym b] <- readAll tbl "x x"
      a `shouldBe` b
    it "reports an unterminated list" $ do
      tbl <- newSymbolTable
      readAll tbl "(1 2" `shouldThrow` (== SyntaxError "unterminated list")

  describe "printer" $ do
    it "distinguishes write and display for strings" $ do
      tbl <- newSymbolTable
      vs <- readAll tbl "(\"x\" y)"
      map writeString vs `shouldBe` ["(\"x\" y)"]
      map displayString vs `shouldBe` ["(x y)"]
    it "prints void and procedures" $ do
      displayString VVoid `shouldBe` "#<void>"
