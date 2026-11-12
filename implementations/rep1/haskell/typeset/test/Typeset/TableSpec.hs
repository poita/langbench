module Typeset.TableSpec (spec) where

import Test.Hspec
import Test.QuickCheck

import Typeset.Layout.Table (columnWidths)

spec :: Spec
spec = do
  it "uses natural widths when they fit" $
    columnWidths 144000 [29530, 15000, 22460] [29530, 15000, 22460] `shouldBe` [29530, 15000, 22460]
  it "falls back to minimum widths when even those do not fit" $
    columnWidths 10 [100, 100] [60, 60] `shouldBe` [60, 60]
  it "shrinks proportionally in between (spec example)" $
    columnWidths 152000 [114120, 83990] [32190, 32190] `shouldBe` [85871, 66129]
  it "fills the available width exactly when shrinking" $
    property $ forAll (choose (1, 6)) $ \k ->
      forAll (vectorOf k (choose (0, 50000))) $ \mins ->
        forAll (vectorOf k (choose (1, 50000))) $ \extras ->
          let nats = zipWith (+) mins extras
              lo = sum mins
              hi = sum nats
          in forAll (choose (lo, hi)) $ \avail ->
               let ws = columnWidths avail nats mins
               in (lo < avail && avail < hi) ==>
                    (sum ws === avail .&&. and (zipWith3 (\w n m -> w <= n && w >= m) ws nats mins))
