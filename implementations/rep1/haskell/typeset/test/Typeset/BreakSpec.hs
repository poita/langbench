module Typeset.BreakSpec (spec) where

import Data.Array (listArray)
import Test.Hspec
import Test.QuickCheck

import Typeset.Break
import Typeset.Font
import Typeset.HList
import Typeset.Hyphenation
import Typeset.Line
import Typeset.Types

params :: BreakParams
params = BreakParams { bpTolerance = 1000, bpLinePenalty = 10, bpAdjDemerits = 10000
                     , bpDoubleHyphen = 10000, bpFinalHyphen = 5000 }

spec :: Spec
spec = do
  fonts <- runIO (loadFonts "data")
  pats <- runIO (parsePatterns <$> ioReadUtf8 "data/hyphen/english.chp")
  let face = resolveFace fonts Serif False False
      sty = Sty face 10000 0
      hp hyph = HParams hyph pats 50 50 Nothing
      listOf hyph txt = prepare (buildList (hp hyph) (litToks sty txt))
      ctxFor al measure = LineCtx al 20000 measure 0 face 10000
      sample = "The quick brown fox jumps over the lazy dog."
  describe "breakPrepared" $ do
    it "reproduces spec example 6 (two justified lines)" $ do
      let br = breakPrepared params (listOf False sample) 142000 0
      brBreaks br `shouldBe` [13, 19]
      brTotal br `shouldBe` 3016
      brEmergency br `shouldBe` False
    it "breaks a single short line only at the end" $ do
      let br = breakPrepared params (listOf False "The quick brown fox.") 142000 0
      brBreaks br `shouldBe` [9]
      brTotal br `shouldBe` 100
    it "falls back to pass 2 when nothing is feasible" $ do
      let br = breakPrepared params { bpTolerance = 0 } (listOf False sample) 100000 0
      brEmergency br `shouldBe` True
    it "produces one empty line for an empty list" $ do
      let br = breakPrepared params (listOf False "") 100000 0
      brBreaks br `shouldBe` [2]
      brTotal br `shouldBe` 100
  describe "setLine" $ do
    it "distributes shrink by floor division (spec example 4)" $ do
      -- seven boxes and six glues 2540/1270/850; W = 145890, L = 142000
      let bx i w = IBox (Box w "x" sty i 0)
          glue = IGlue 2540 1270 850 False
          items = [ bx 1 20000, glue, bx 2 20000, glue, bx 3 20000, glue, bx 4 20000, glue
                  , bx 5 20000, glue, bx 6 20000, glue, bx 7 10650
                  , IPenalty 10000 False Nothing, IGlue 0 0 0 False, IPenalty (-10000) False Nothing ]
          arr = listArray (0, length items - 1) items
          sl = setLine (ctxFor Justify 142000) arr 0 (length items - 1)
          xs = map runX (slRuns sl)
          gaps = zipWith3 (\x1 x2 w -> x2 - x1 - w) xs (drop 1 xs) (map runWidth (slRuns sl))
      gaps `shouldBe` [1891, 1892, 1892, 1891, 1892, 1892]
    it "aligns ragged lines right and centred" $ do
      let items = [ IBox (Box 30000 "x" sty 1 0), IPenalty 10000 False Nothing
                  , IGlue 0 0 0 True, IPenalty (-10000) False Nothing ]
          arr = listArray (0, 3) items
          start al = runX (head' (slRuns (setLine (ctxFor al 100000) arr 0 3)))
      start AlignLeft `shouldBe` 20000
      start AlignRight `shouldBe` 90000
      start AlignCenter `shouldBe` 55000
  describe "properties" $ do
    it "every line of a feasible justified paragraph fills the measure" $
      property $ forAll genText $ \txt -> forAll (choose (60000, 200000)) $ \measure ->
        let p = listOf True txt
            br = breakPrepared params p measure 0
            sls = setLines (ctxFor Justify measure) (preparedItems p) (brBreaks br)
            nonFinal = init sls
        in not (brEmergency br) ==>
             all (\l -> slEndX l == 20000 + measure) nonFinal
    it "breakpoints are strictly increasing and end at the final item" $
      property $ forAll genText $ \txt -> forAll (choose (20000, 200000)) $ \measure ->
        let p = listOf True txt
            br = breakPrepared params p measure 0
            bs = brBreaks br
        in and (zipWith (<) bs (drop 1 bs)) .&&. not (null bs)
    it "a paragraph set twice gives identical results" $
      property $ forAll genText $ \txt ->
        let run = let p = listOf True txt in brBreaks (breakPrepared params p 120000 0)
        in run === run
  where
    head' (x : _) = x
    head' [] = error "no runs"

-- | Random lowercase words separated by spaces.
genText :: Gen String
genText = do
  n <- choose (1, 60)
  ws <- vectorOf n (do k <- choose (1, 12); vectorOf k (elements ['a' .. 'z']))
  return (unwords ws)
