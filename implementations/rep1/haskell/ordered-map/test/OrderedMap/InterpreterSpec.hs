{-# LANGUAGE OverloadedStrings #-}
module OrderedMap.InterpreterSpec (spec) where

import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Either (isLeft)
import OrderedMap.Interpreter
import Test.Hspec

run :: B.ByteString -> Either String BL.ByteString
run = fmap BB.toLazyByteString . runScript

spec :: Spec
spec = do
  it "spec example 1" $
    run (B.unlines
      [ "12", "size", "min", "insert 5 five", "insert 5 FIVE", "get 5"
      , "insert 2 two", "insert 9 nine", "min", "max", "range 2 9"
      , "delete 5", "range 3 8" ])
      `shouldBe` Right (BL.unlines
      [ "0", "empty", "ok", "updated", "FIVE", "ok", "ok", "2", "9"
      , "2 5 9", "ok", "empty" ])
  it "spec example 3 (extreme keys)" $
    run (B.unlines
      [ "9", "insert -9223372036854775808 lo", "insert 9223372036854775807 hi"
      , "insert 0 zero", "succ 9223372036854775807", "pred -9223372036854775808"
      , "floor -9223372036854775807", "ceil 1"
      , "range -9223372036854775808 9223372036854775807", "delete 0" ])
      `shouldBe` Right (BL.unlines
      [ "ok", "ok", "ok", "missing", "missing", "-9223372036854775808"
      , "9223372036854775807"
      , "-9223372036854775808 0 9223372036854775807", "ok" ])
  it "produces no output for Q = 0" $
    run "0\n" `shouldBe` Right ""
  it "accepts a final line without a newline" $
    run "2\ninsert 1 a\nget 1" `shouldBe` Right "ok\na\n"
  it "distinguishes empty from missing" $
    run "5\nmin\nmax\nselect 0\nfloor 1\nget 1\n"
      `shouldBe` Right "empty\nempty\nmissing\nmissing\nmissing\n"
  it "ignores lo > hi in range" $
    run "3\ninsert 1 a\nrange 5 1\nrank 100\n" `shouldBe` Right "ok\nempty\n1\n"
  it "reports malformed scripts" $ do
    run "1\nbogus\n" `shouldSatisfy` isLeft
    run "3\nsize\n" `shouldSatisfy` isLeft
    run "x\n" `shouldSatisfy` isLeft
