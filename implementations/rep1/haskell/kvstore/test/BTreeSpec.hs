{-# LANGUAGE OverloadedStrings #-}

-- | Model-based tests: random workloads against a 'Data.Map' model.
module BTreeSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import Test.Hspec
import Test.QuickCheck
import Test.QuickCheck.Monadic
import Tessera.Path (parsePath)
import Tessera.Query
import Tessera.Store (Store)
import qualified Tessera.Store as Store
import Tessera.Value

data Op = PutOp BS.ByteString Value | DelOp BS.ByteString | CheckpointOp
  deriving (Show)

keyGen :: Gen BS.ByteString
keyGen =
  frequency
    [ (6, BC.pack . ("k" ++) . show <$> choose (0 :: Int, 80))
    , (1, BC.pack . (++ "z") . flip replicate 'q' <$> choose (0, 120))
    ]

-- | Documents of many sizes, so that leaves split and overflow chains of
-- several pages appear.
docGen :: Gen Value
docGen =
  frequency
    [ (5, VInt <$> arbitrary)
    , (3, VList . map VInt <$> (choose (0, 60) >>= \n -> vectorOf n (arbitrary :: Gen Int64)))
    , (1, VString . BC.pack . flip replicate 'x' <$> choose (0, 4000))
    ]

instance Arbitrary Op where
  arbitrary =
    frequency
      [ (5, PutOp <$> keyGen <*> docGen)
      , (4, DelOp <$> keyGen)
      , (1, pure CheckpointOp)
      ]

apply :: Store -> Map.Map BS.ByteString Value -> Op -> IO (Map.Map BS.ByteString Value)
apply db m op = case op of
  PutOp k v -> Map.insert k v m <$ Store.put db k v
  DelOp k -> Map.delete k m <$ Store.delete db k
  CheckpointOp -> m <$ Store.checkpoint db

scanAll :: Store -> ScanOptions -> IO [(BS.ByteString, Value)]
scanAll db o = either (error . show) (map (\(k, Just v) -> (k, v))) <$> Store.scan db o

spec :: Spec
spec = describe "B+tree behaviour under random workloads" $ do
  it "agrees with a Data.Map model (scan, reverse scan, get, count)" $
    withMaxSuccess 60 $ property $ \(ops :: [Op]) -> monadicIO $ do
      (ok, msg) <- run $ do
        db <- Store.newStore
        model <- foldlM' (apply db) Map.empty ops
        fwd <- scanAll db defaultScanOptions
        rev <- scanAll db defaultScanOptions {scanReverse = True}
        st <- Store.stat db
        gets <- mapM (\k -> Store.get db k) (Map.keys model)
        let expected = Map.toAscList model
        pure
          ( fwd == expected && rev == reverse expected && Store.statDocs st == Map.size model
              && gets == map Right (Map.elems model)
          , show (length fwd, length expected)
          )
      monitor (counterexample msg)
      assert ok
  it "answers bounded and limited scans like the model" $
    withMaxSuccess 40 $ property $ \(ops :: [Op]) (lo :: Int) (hi :: Int) (lim :: Int) -> monadicIO $ do
      ok <- run $ do
        db <- Store.newStore
        model <- foldlM' (apply db) Map.empty ops
        let from = BC.pack ("k" ++ show (abs lo `mod` 90))
            to = BC.pack ("k" ++ show (abs hi `mod` 90))
            n = abs lim `mod` 10
            inRange = [(k, v) | (k, v) <- Map.toAscList model, k >= from, k < to]
        a <- scanAll db defaultScanOptions {scanFrom = Just from, scanTo = Just to, scanLimit = Just n}
        b <- scanAll db defaultScanOptions {scanFrom = Just from, scanTo = Just to, scanLimit = Just n, scanReverse = True}
        pure (a == take n inRange && b == take n (reverse inRange))
      assert ok
  it "survives a checkpoint and a reopen" $
    withMaxSuccess 30 $ property $ \(ops :: [Op]) -> monadicIO $ do
      ok <- run $ do
        db <- Store.newStore
        _ <- foldlM' (apply db) Map.empty ops
        f <- Store.storeFileBytes db
        l <- Store.storeLogBytes db
        db2 <- Store.openStore (Just f) (Just l)
        (==) <$> scanAll db defaultScanOptions <*> scanAll db2 defaultScanOptions
      assert ok
  it "keeps a secondary index consistent with the documents" $
    withMaxSuccess 40 $ property $ \(ops :: [Op]) -> monadicIO $ do
      ok <- run $ do
        db <- Store.newStore
        model <- foldlM' (apply db) Map.empty (take 30 ops)
        _ <- Store.createIndex db =<< pathOf "n"
        mapM_ (\(i, k) -> Store.put db k (VObject (Map.fromList [("n", VInt (fromIntegral (i `mod` 7)))]))) (zip [0 :: Int ..] (Map.keys model))
        ixs <- Store.indexes db
        total <- scanAll db defaultScanOptions
        pure (map Store.indexEntries ixs == [length [() | (_, VObject o) <- total, Map.member "n" o]])
      assert ok
  where
    foldlM' f z xs = go z xs where go acc [] = pure acc; go acc (y : ys) = f acc y >>= \a -> a `seq` go a ys
    pathOf s = either (error . show) pure (parsePath s)
