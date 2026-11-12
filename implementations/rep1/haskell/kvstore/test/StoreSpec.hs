{-# LANGUAGE OverloadedStrings #-}

module StoreSpec (spec) where

import Helpers
import Test.Hspec
import Tessera.Error
import Tessera.Parser (parsePred, parseValue)
import Tessera.Path (Path, parsePath)
import Tessera.Query
import Tessera.Store (PutOutcome (..), Store)
import qualified Tessera.Store as Store
import Tessera.Value

doc :: String -> Value
doc = either (error . show) id . parseValue . bs

path :: String -> Path
path = either (error . show) id . parsePath . bs

fresh :: IO Store
fresh = Store.newStore

spec :: Spec
spec = describe "Tessera.Store" $ do
  it "puts, gets and replaces" $ do
    db <- fresh
    Store.put db "a" (doc "{x:1}") `shouldReturn` Right Created
    Store.put db "a" (doc "{x:2}") `shouldReturn` Right Replaced
    Store.get db "a" `shouldReturn` Right (doc "{x:2}")
    Store.get db "zz" `shouldReturn` Left NotFound
    Store.put db "" VNull `shouldReturn` Left BadKey
  it "deletes" $ do
    db <- fresh
    _ <- Store.put db "a" VNull
    Store.delete db "a" `shouldReturn` Right ()
    Store.delete db "a" `shouldReturn` Left NotFound
    Store.stat db >>= \s -> (Store.statDocs s, Store.statRoot s) `shouldBe` (0, 0)
  it "rejects oversized and too-deep documents without changing anything" $ do
    db <- fresh
    Store.put db "big" (VString (bs (replicate 70000 'x'))) `shouldReturn` Left DocTooLarge
    Store.put db "deep" (iterate (VList . pure) VNull !! 40) `shouldReturn` Left Depth
    Store.stat db >>= \s -> (Store.statCommits s, Store.statPages s) `shouldBe` (0, 1)
  it "updates and unsets paths" $ do
    db <- fresh
    _ <- Store.put db "u" (doc "{name:\"ada\"}")
    Store.update db "u" (path "addr.city") (VString "oslo") `shouldReturn` Right ()
    Store.get db "u" `shouldReturn` Right (doc "{name:\"ada\",addr:{city:\"oslo\"}}")
    Store.update db "u" (path "name.first") VNull `shouldReturn` Left NotObject
    Store.unset db "u" (path "addr.zip") `shouldReturn` Left NoField
    Store.unset db "u" (path "addr.city") `shouldReturn` Right ()
    Store.get db "u" `shouldReturn` Right (doc "{name:\"ada\",addr:{}}")
  it "scans in both directions with bounds and limits" $ do
    db <- fresh
    mapM_ (\k -> Store.put db k (VString k)) ["a", "b", "c", "d"]
    let keys o = fmap (map fst) <$> Store.scan db o
    keys defaultScanOptions `shouldReturn` Right ["a", "b", "c", "d"]
    keys defaultScanOptions {scanFrom = Just "b", scanTo = Just "d"} `shouldReturn` Right ["b", "c"]
    keys defaultScanOptions {scanReverse = True, scanLimit = Just 2} `shouldReturn` Right ["d", "c"]
    keys defaultScanOptions {scanReverse = True, scanFrom = Just "b", scanTo = Just "d"} `shouldReturn` Right ["c", "b"]
    keys defaultScanOptions {scanFrom = Just "d", scanTo = Just "b"} `shouldReturn` Right []
    Store.scan db defaultScanOptions {scanKeysOnly = True, scanLimit = Just 1} `shouldReturn` Right [("a", Nothing)]
  it "finds with and without an index, reporting the plan" $ do
    db <- fresh
    _ <- Store.put db "u1" (doc "{name:\"ada\",age:36}")
    _ <- Store.put db "u2" (doc "{name:\"bob\",age:29}")
    _ <- Store.put db "u3" (doc "{name:\"cy\",age:36}")
    let find' s = fmap (\(p, r) -> (p, map fst r)) <$> Store.find db (either (error . show) id (parsePred s)) Nothing
    find' "age == 36" `shouldReturn` Right (PlanScan, ["u1", "u3"])
    Store.createIndex db (path "age") `shouldReturn` Right 3
    find' "age == 36" `shouldReturn` Right (PlanIndex (path "age"), ["u1", "u3"])
    find' "age > 30 and name == \"cy\"" `shouldReturn` Right (PlanIndex (path "age"), ["u3"])
    find' "not(age == 36)" `shouldReturn` Right (PlanScan, ["u2"])
    Store.createIndex db (path "age") `shouldReturn` Left IndexExists
    Store.dropIndex db (path "age") `shouldReturn` Right 1
    Store.dropIndex db (path "age") `shouldReturn` Left IndexMissing
  it "keeps indexes exact under writes" $ do
    db <- fresh
    _ <- Store.createIndex db (path "n")
    mapM_ (\i -> Store.put db (bs ("k" ++ show i)) (doc ("{n:" ++ show (i `mod` 5) ++ "}"))) [0 .. 49 :: Int]
    mapM_ (\i -> Store.delete db (bs ("k" ++ show i))) [0, 5 .. 45 :: Int]
    _ <- Store.update db "k1" (path "n") (VString "s")
    _ <- Store.unset db "k2" (path "n")
    ixs <- Store.indexes db
    map Store.indexEntries ixs `shouldBe` [50 - 10 - 1]
  it "rejects over-long index keys" $ do
    db <- fresh
    _ <- Store.createIndex db (path "s")
    Store.put db "k" (doc ("{s:\"" ++ replicate 130 'x' ++ "\"}")) `shouldReturn` Left IndexKeyTooLong
    Store.put db "k" (doc ("{s:\"" ++ replicate 124 'x' ++ "\"}")) `shouldReturn` Right Created
  it "limits the number of indexes" $ do
    db <- fresh
    mapM_ (\i -> Store.createIndex db (path ("f" ++ show i))) [1 .. 16 :: Int]
    Store.createIndex db (path "g") `shouldReturn` Left IndexLimit
  describe "transactions" $ do
    it "rolls back" $ do
      db <- fresh
      Store.begin db `shouldReturn` Right ()
      Store.begin db `shouldReturn` Left TxnActive
      _ <- Store.put db "a" VNull
      Store.checkpoint db `shouldReturn` Left TxnActive
      Store.rollback db `shouldReturn` Right ()
      Store.rollback db `shouldReturn` Left NoTxn
      Store.get db "a" `shouldReturn` Left NotFound
      Store.stat db >>= \s -> Store.statPages s `shouldBe` 1
    it "commits and reports the frame count" $ do
      db <- fresh
      _ <- Store.begin db
      _ <- Store.put db "a" VNull
      Store.commit db `shouldReturn` Right (1, 2)
      Store.commit db `shouldReturn` Left NoTxn
  it "reopens from its own files" $ do
    db <- fresh
    mapM_ (\i -> Store.put db (bs (show i)) (VInt i)) [1 .. 300]
    _ <- Store.checkpoint db
    _ <- Store.put db "late" VNull
    f <- Store.storeFileBytes db
    l <- Store.storeLogBytes db
    db2 <- Store.openStore (Just f) (Just l)
    r1 <- Store.scan db defaultScanOptions
    r2 <- Store.scan db2 defaultScanOptions
    r2 `shouldBe` r1
    fmap length r2 `shouldBe` Right 301
