module Data.OrderedMapSpec (spec) where

import Data.List (foldl', nub, sort)
import qualified Data.OrderedMap as OM
import Data.OrderedMap.Internal (height, valid)
import Prelude hiding (lookup)
import Test.Hspec
import Test.QuickCheck

type M = OM.OrderedMap Int String

-- | Reference model: a sorted association list with unique keys.
type Model = [(Int, String)]

modelInsert :: Int -> String -> Model -> Model
modelInsert k v m = sort' ((k, v) : filter ((/= k) . fst) m)
  where sort' = foldr ins []
        ins x [] = [x]
        ins x (y : ys) | fst x <= fst y = x : y : ys
                       | otherwise = y : ins x ys

modelDelete :: Int -> Model -> Model
modelDelete k = filter ((/= k) . fst)

data Op = Ins Int String | Del Int deriving (Show)

instance Arbitrary Op where
  arbitrary = frequency
    [ (3, Ins <$> smallKey <*> listOf1 (elements "abc"))
    , (2, Del <$> smallKey) ]
  shrink (Ins k v) = [Ins k' v | k' <- shrink k]
  shrink (Del k) = [Del k' | k' <- shrink k]

-- Small key space forces collisions; extremes exercise overflow handling.
smallKey :: Gen Int
smallKey = frequency
  [ (8, choose (-20, 20))
  , (1, pure minBound)
  , (1, pure maxBound) ]

apply :: (M, Model) -> Op -> (M, Model)
apply (m, ref) (Ins k v) = (OM.insert k v m, modelInsert k v ref)
apply (m, ref) (Del k) = (OM.delete k m, modelDelete k ref)

build :: [Op] -> (M, Model)
build = foldl' apply (OM.empty, [])

spec :: Spec
spec = do
  describe "basic behaviour" $ do
    it "empty map" $ do
      OM.null (OM.empty :: M) `shouldBe` True
      OM.size (OM.empty :: M) `shouldBe` 0
      OM.lookupMin (OM.empty :: M) `shouldBe` Nothing
      OM.rank 5 (OM.empty :: M) `shouldBe` 0
      OM.select 0 (OM.empty :: M) `shouldBe` Nothing
      OM.range 0 10 (OM.empty :: M) `shouldBe` []
    it "insertLookup / deleteLookup report previous values" $ do
      let (o1, m1) = OM.insertLookup 1 "a" (OM.empty :: M)
          (o2, m2) = OM.insertLookup 1 "b" m1
          (o3, m3) = OM.deleteLookup 1 m2
          (o4, _) = OM.deleteLookup 1 m3
      (o1, o2, o3, o4) `shouldBe` (Nothing, Just "a", Just "b", Nothing)
    it "worked example from the spec" $ do
      let m = OM.fromList [(10, "a"), (20, "b"), (30, "c")] :: M
      OM.lookupFloor 25 m `shouldBe` Just (20, "b")
      OM.lookupCeil 25 m `shouldBe` Just (30, "c")
      OM.lookupSucc 30 m `shouldBe` Nothing
      OM.lookupPred 10 m `shouldBe` Nothing
      OM.rank 21 m `shouldBe` 2
      OM.select 2 m `shouldBe` Just (30, "c")
      OM.select 3 m `shouldBe` Nothing
    it "neighbour queries do not overflow at the extremes" $ do
      let m = OM.fromList [(minBound, "lo"), (0, "z"), (maxBound, "hi")] :: M
      OM.lookupSucc maxBound m `shouldBe` Nothing
      OM.lookupPred minBound m `shouldBe` Nothing
      OM.lookupCeil maxBound m `shouldBe` Just (maxBound, "hi")
      OM.lookupFloor minBound m `shouldBe` Just (minBound, "lo")
      OM.keys (OM.fromList [(minBound, ""), (maxBound, "")] :: M)
        `shouldBe` [minBound, maxBound]
      OM.rangeKeys minBound maxBound m `shouldBe` [minBound, 0, maxBound]
    it "select with negative index is Nothing" $
      OM.select (-1) (OM.fromList [(1, "x")] :: M) `shouldBe` Nothing
    it "range with lo > hi is empty" $
      OM.range 5 1 (OM.fromList [(1, "a"), (3, "b"), (5, "c")] :: M) `shouldBe` []

  describe "balance" $ do
    let n = 100000
        logBound h = fromIntegral h <= 1.45 * logBase 2 (fromIntegral n + 2 :: Double)
    it "stays balanced under ascending insertion" $ do
      let m = foldl' (\a k -> OM.insert k "v" a) OM.empty [1 .. n] :: M
      OM.size m `shouldBe` n
      logBound (height m) `shouldBe` True
      valid m `shouldBe` True
    it "stays balanced under descending deletion" $ do
      let full = foldl' (\a k -> OM.insert k "v" a) OM.empty [1 .. n] :: M
          m = foldl' (flip OM.delete) full [n, n - 1 .. n `div` 2 + 1]
      OM.size m `shouldBe` n `div` 2
      logBound (height m) `shouldBe` True
      valid m `shouldBe` True

  describe "properties (against a sorted-list model)" $ do
    it "invariants hold after every operation sequence" $ property $ \ops ->
      valid (fst (build ops))
    it "toAscList / size agree with the model" $ property $ \ops ->
      let (m, ref) = build ops in OM.toAscList m == ref && OM.size m == length ref
    it "lookup / member" $ property $ \ops k ->
      let (m, ref) = build ops
      in OM.lookup k m == lookup' k ref && OM.member k m == (lookup' k ref /= Nothing)
    it "min / max" $ property $ \ops ->
      let (m, ref) = build ops
      in OM.lookupMin m == safeHead ref && OM.lookupMax m == safeHead (reverse ref)
    it "floor / ceil / succ / pred" $ property $ \ops k ->
      let (m, ref) = build ops
      in OM.lookupFloor k m == safeHead (reverse (filter ((<= k) . fst) ref))
         && OM.lookupCeil k m == safeHead (filter ((>= k) . fst) ref)
         && OM.lookupSucc k m == safeHead (filter ((> k) . fst) ref)
         && OM.lookupPred k m == safeHead (reverse (filter ((< k) . fst) ref))
    it "rank / select" $ property $ \ops k i ->
      let (m, ref) = build ops
          i' = i `mod` (length ref + 2)
      in OM.rank k m == length (filter ((< k) . fst) ref)
         && OM.select i' m == (if i' < length ref then Just (ref !! i') else Nothing)
    it "select . rank round-trips for present keys" $ property $ \ops ->
      let (m, ref) = build ops
      in all (\(k, v) -> OM.select (OM.rank k m) m == Just (k, v)) ref
    it "range" $ property $ \ops lo hi ->
      let (m, ref) = build ops
      in OM.range lo hi m == filter (\(k, _) -> lo <= k && k <= hi) ref
    it "delete of an absent key leaves the map equal" $ property $ \ops k ->
      let (m, ref) = build ops
      in k `elem` map fst ref || OM.toAscList (OM.delete k m) == ref
    it "fromList keeps the last value for duplicate keys" $ property $ \kvs ->
      let m = OM.fromList kvs :: M
      in OM.keys m == sort (nub (map fst kvs))
         && all (\k -> OM.lookup k m == Just (snd (last (filter ((== k) . fst) kvs))))
                (map fst kvs)
  where
    lookup' k = fmap snd . safeHead . filter ((== k) . fst)
    safeHead [] = Nothing
    safeHead (x : _) = Just x
