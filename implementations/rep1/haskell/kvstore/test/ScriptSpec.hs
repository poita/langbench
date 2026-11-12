{-# LANGUAGE OverloadedStrings #-}

module ScriptSpec (spec) where

import qualified Data.ByteString as BS
import Examples (examples)
import Helpers
import Test.Hspec
import Tessera.Script

spec :: Spec
spec = do
  describe "worked examples of the specification" $
    mapM_ (\(name, cmds, expected) -> it name (runText cmds `shouldReturn` expected)) examples
  describe "the three output files" $ do
    it "an empty script leaves a fresh database and an empty log" $ do
      r <- runFull ""
      resultsText r `shouldBe` ""
      BS.length (resultsDatabase r) `shouldBe` 1024
      BS.take 16 (resultsDatabase r) `shouldBe` hexBytes [0x54, 0x45, 0x53, 0x53, 0x45, 0x52, 0x41, 0x31, 0, 1, 4, 0, 0, 0, 0, 1]
      BS.length (resultsLog r) `shouldBe` 32
    it "treats a trailing LF as a terminator, not a new line" $ do
      runText "begin\n" `shouldReturn` "[1] ok begin\n"
      runText "begin\n\n" `shouldReturn` "[1] ok begin\n[2] error syntax\n"
      runText "begin\nrollback" `shouldReturn` "[1] ok begin\n[2] ok rollback\n"
    it "is byte-exact for the single-document example (checkpointed)" $ do
      r <- runFull "put \"a\" 1\ncheckpoint\n"
      resultsLog r `shouldBe` BS.pack [0x54, 0x45, 0x53, 0x53, 0x57, 0x41, 0x4c, 0x31, 0, 1, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x51, 0xe7, 0x21, 0x53]
      BS.length (resultsDatabase r) `shouldBe` 2048
      BS.take 48 (resultsDatabase r)
        `shouldBe` hexBytes
          [ 0x54, 0x45, 0x53, 0x53, 0x45, 0x52, 0x41, 0x31, 0x00, 0x01, 0x04, 0x00, 0x00, 0x00, 0x00, 0x02
          , 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01
          , 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
          ]
      -- the leaf page of the specification
      BS.drop (1024 + 0x3e0) (resultsDatabase r)
        `shouldBe` hexBytes
          [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 9, 0, 9, 0, 0, 0, 0, 0x61, 3, 0, 0, 0, 0, 0, 0, 0, 1]
    it "appends the documented log records for the first commit" $ do
      r <- runFull "put \"a\" 1\n"
      BS.length (resultsLog r) `shouldBe` 2152
      BS.take 24 (BS.drop 32 (resultsLog r))
        `shouldBe` hexBytes [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 4, 0, 0x76, 0x29, 0x2e, 0x36]
      BS.drop (2152 - 24) (resultsLog r)
        `shouldBe` hexBytes [2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0xa8, 0xa0, 0xaa, 0x22]
    it "rolls back a transaction left open at the end" $ do
      r <- runFull "begin\nput \"a\" 1\n"
      BS.length (resultsLog r) `shouldBe` 32
    it "checkpoints automatically when the log reaches 262144 bytes" $ do
      let cmds = concat ["put \"k" ++ show i ++ "\" " ++ show i ++ "\n" | i <- [1 .. 130 :: Int]] ++ "stat\n"
      r <- runFull cmds
      -- 130 commits of 2120 bytes would be 275600 bytes; the log was reset once
      BS.length (resultsLog r) < 262144 `shouldBe` True
      BS.length (resultsDatabase r) > 1024 `shouldBe` True
