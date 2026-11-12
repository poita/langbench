module Spreadsheet.GraphSpec (spec) where

import Data.List (sort)
import qualified Data.IntMap.Strict as IntMap
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Spreadsheet.Graph

graph :: [(Int, [Int])] -> Int -> [Int]
graph es = \n -> IntMap.findWithDefault [] n (IntMap.fromList es)

norm :: [Component] -> [Component]
norm = map f
  where
    f (Cyclic ns) = Cyclic (sort ns)
    f c = c

spec :: Spec
spec = do
  it "emits successors before predecessors" $
    components (graph [(1, [2]), (2, [3]), (3, [])]) [1, 2, 3]
      `shouldBe` [Acyclic 3, Acyclic 2, Acyclic 1]
  it "finds a multi-node cycle" $
    norm (components (graph [(1, [2]), (2, [3]), (3, [1, 4]), (4, [])]) [1])
      `shouldBe` [Acyclic 4, Cyclic [1, 2, 3]]
  it "treats a self loop as a cycle" $
    components (graph [(1, [1])]) [1] `shouldBe` [Cyclic [1]]
  it "visits every root once" $
    components (graph []) [5, 5, 6] `shouldBe` [Acyclic 5, Acyclic 6]
  it "handles a long chain" $
    length (components (\n -> [n + 1 | n < 100000]) [0]) `shouldBe` 100001
  prop "components partition the nodes and respect edge order" $
    forAll (listOf (choose (0, 9) >>= \a -> (,) a <$> listOf (choose (0, 9)))) $ \es ->
      let succs = graph es
          nodes = [0 .. 9]
          cs = components succs nodes
          members c = case c of Acyclic n -> [n]; Cyclic ns -> ns
          pos = IntMap.fromList [(n, i) | (i, c) <- zip [0 :: Int ..] cs, n <- members c]
       in conjoin
            [ sort (concatMap members cs) === nodes
            , conjoin [IntMap.findWithDefault (-1) w pos <= IntMap.findWithDefault (-1) v pos | v <- nodes, w <- succs v]
            ]
