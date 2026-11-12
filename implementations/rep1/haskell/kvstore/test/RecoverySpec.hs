{-# LANGUAGE OverloadedStrings #-}

module RecoverySpec (spec) where

import qualified Data.ByteString as BS
import Helpers
import Test.Hspec
import Tessera.Script
import Tessera.WAL

spec :: Spec
spec = describe "recovery" $ do
  full <- runIO (runFull "put \"a\" 1\nput \"b\" 2\n")
  let log' = resultsLog full
      fresh = BS.take 1024 (resultsDatabase full)
  it "keeps committed transactions and drops a torn one (cut mid-record)" $ do
    r <- run (Just fresh) (Just (BS.take 3000 log')) "scan\nstat\nput \"c\" 3\nstat\n"
    unbs (resultsText r)
      `shouldBe` unlines
        [ "[1] ok scan 1", "  \"a\" = 1", "[2] ok stat", "  pages 2", "  free 0", "  freehead 0", "  docs 1"
        , "  root 2", "  height 1", "  commits 1", "  indexes 0", "  wal 2152"
        , "[3] ok put created", "[4] ok stat", "  pages 2", "  free 0", "  freehead 0", "  docs 2"
        , "  root 2", "  height 1", "  commits 2", "  indexes 0", "  wal 4272"
        ]
    BS.length (resultsLog r) `shouldBe` 4272
    resultsDatabase r `shouldBe` fresh
  it "recovers every prefix to the last complete commit" $
    mapM_
      ( \cut -> do
          r <- run (Just fresh) (Just (BS.take cut log')) "stat\n"
          let expectedWal
                | cut >= 4272 = 4272
                | cut >= 2152 = 2152
                | otherwise = 32
          unbs (resultsText r) `shouldContain` ("wal " ++ show (expectedWal :: Int))
          BS.length (resultsLog r) `shouldBe` expectedWal
      )
      [0, 10, 31, 32, 55, 1079, 1080, 2127, 2128, 2151, 2152, 2176, 3199, 3200, 4247, 4248, 4271, 4272]
  it "discards a log with a damaged header" $ do
    r <- run (Just fresh) (Just (BS.pack [1 .. 10])) "scan\n"
    unbs (resultsText r) `shouldBe` "[1] ok scan 0\n"
    resultsLog r `shouldBe` walHeader
    let badCrc = BS.take 28 log' <> BS.pack [0, 0, 0, 0] <> BS.drop 32 log'
    r2 <- run (Just fresh) (Just badCrc) "scan\n"
    unbs (resultsText r2) `shouldBe` "[1] ok scan 0\n"
  it "stops at a record with a bad checksum and drops trailing garbage" $ do
    let flipped = BS.take 2200 log' <> BS.map (+ 1) (BS.take 1 (BS.drop 2200 log')) <> BS.drop 2201 log'
    r <- run (Just fresh) (Just flipped) "scan\n"
    unbs (resultsText r) `shouldBe` "[1] ok scan 1\n  \"a\" = 1\n"
    r2 <- run (Just fresh) (Just (log' <> "garbage")) "scan keys\n"
    unbs (resultsText r2) `shouldBe` "[1] ok scan 2\n  \"a\"\n  \"b\"\n"
    BS.length (resultsLog r2) `shouldBe` 4272
  it "replays a log on top of a missing database" $ do
    r <- run Nothing (Just log') "scan keys\n"
    unbs (resultsText r) `shouldBe` "[1] ok scan 2\n  \"a\"\n  \"b\"\n"
  it "applies a recovered log through a later checkpoint" $ do
    r <- run (Just fresh) (Just log') "checkpoint\nstat\n"
    unbs (resultsText r) `shouldContain` "ok checkpoint pages 2"
    BS.length (resultsDatabase r) `shouldBe` 2048
    BS.length (resultsLog r) `shouldBe` 32
