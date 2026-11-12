module Main (main) where

import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Array.Unboxed (listArray)
import Test.Hspec
import Test.QuickCheck hiding (Result)

import Control.Monad.ST (runST)

import Sat
import Sat.Solver (newSolverWith, addClause, solverStats, Stats (..))
import qualified Sat.Solver as S
import Sat.Luby (luby, lubySequence)

-- | Reference decision procedure: try all assignments.
bruteForce :: CNF -> Bool
bruteForce cnf = any ok [0 .. 2 ^ n - 1 :: Int]
  where
    n = cnfNumVars cnf
    ok bits = all (any (lit bits)) (cnfClauses cnf)
    lit bits l
      | l > 0 = testBit' bits (l - 1)
      | otherwise = not (testBit' bits (negate l - 1))
    testBit' b i = (b `div` 2 ^ i) `mod` 2 == 1

isSat :: Result -> Bool
isSat (Sat _) = True
isSat Unsat = False

-- | Check an answer against the formula (and against brute force if small).
sound :: CNF -> Result -> Bool
sound cnf (Sat m) = satisfies m cnf
sound cnf Unsat = not (bruteForce cnf)

-- | Aggressive settings: restart every couple of conflicts and reduce the
-- learnt database all the time.
stress :: Config
stress = Config { cfgRestartBase = 2, cfgMinLearnts = 1, cfgLearntFactor = 1.05 }

genCNF :: Int -> Int -> Gen CNF
genCNF maxVars maxClauses = do
  n <- choose (0, maxVars)
  m <- choose (0, maxClauses)
  cs <- vectorOf m $
    if n == 0
      then return []
      else do
        k <- frequency [(1, return 0), (2, return 1), (4, choose (2, 3)), (2, choose (4, 6))]
        vectorOf k (do v <- choose (1, n); s <- arbitrary; return (if s then v else negate v))
  return (CNF n cs)

-- | Uniform random 3-SAT with distinct variables per clause.
rand3 :: Int -> Int -> Gen CNF
rand3 n m = CNF n <$> vectorOf m clause
  where
    clause = do
      vs <- shuffle [1 .. n]
      signs <- vectorOf 3 arbitrary
      return [ if sg then v else negate v | (v, sg) <- zip (take 3 vs) signs ]

pigeonhole :: Int -> CNF
pigeonhole holes = pigeons' (holes + 1) holes

-- | @pigeons' p h@: p pigeons into h holes (satisfiable iff p <= h).
pigeons' :: Int -> Int -> CNF
pigeons' pigeons holes = CNF (pigeons * holes) (atLeast ++ atMost)
  where
    var p h = p * holes + h + 1
    atLeast = [ [ var p h | h <- [0 .. holes - 1] ] | p <- [0 .. pigeons - 1] ]
    atMost = [ [negate (var p h), negate (var q h)]
             | h <- [0 .. holes - 1], p <- [0 .. pigeons - 1], q <- [p + 1 .. pigeons - 1] ]

render :: Result -> String
render = BL.unpack . B.toLazyByteString . renderResult

parse :: String -> Either String CNF
parse = parseDimacs . BS.pack

main :: IO ()
main = hspec $ do
  describe "Sat.Luby" $ do
    it "produces the Luby sequence" $
      take 15 (lubySequence 2) `shouldBe` [1, 1, 2, 1, 1, 2, 4, 1, 1, 2, 1, 1, 2, 4, 8]
    it "scales by the base" $
      map (luby 3) [0 .. 5] `shouldBe` [1, 1, 3, 1, 1, 3]

  describe "Sat.Dimacs.parseDimacs" $ do
    it "parses a simple formula" $
      parse "c hi\np cnf 3 2\n1 -2 0\n2 3 0\n" `shouldBe` Right (CNF 3 [[1, -2], [2, 3]])
    it "accepts clauses spanning lines and several clauses per line" $
      parse "p cnf 2 4\n1 2\n0 -1 2 0\n-1 -2 0 1 -2 0" `shouldBe`
        Right (CNF 2 [[1, 2], [-1, 2], [-1, -2], [1, -2]])
    it "ignores comments between the numbers of a clause, blank lines and blanks" $
      parse "  \t c x\np  cnf\t1 1\n\n \t1\ncfoo\n  c\n -1 \t0 \nc end" `shouldBe`
        Right (CNF 1 [[1, -1]])
    it "keeps empty clauses, repeats and tautologies" $
      parse "p cnf 2 3\n0\n1 1 -2 0\n1 -1 0\n" `shouldBe` Right (CNF 2 [[], [1, 1, -2], [1, -1]])
    it "rejects data before the header and unterminated clauses" $ do
      parse "1 0\np cnf 1 1\n" `shouldSatisfy` either (const True) (const False)
      parse "p cnf 1 1\n1" `shouldSatisfy` either (const True) (const False)
    it "round-trips through renderCNF" $ property $
      forAll (genCNF 6 10) $ \cnf ->
        let txt = BL.toStrict (B.toLazyByteString (renderCNF cnf))
        in parseDimacs txt === Right cnf

  describe "Sat.Dimacs.renderResult" $ do
    it "prints UNSAT" $ render Unsat `shouldBe` "UNSAT\n"
    it "prints a model line ending in 0" $
      render (Sat (listArray (1, 3) [True, False, True])) `shouldBe` "SAT\n1 -2 3 0\n"
    it "prints just 0 for no variables" $
      render (Sat (listArray (1, 0) [])) `shouldBe` "SAT\n0\n"

  describe "Sat.solve on the specification's examples" $ do
    it "solves the first example" $
      case solve (CNF 3 [[1, -2], [2, 3]]) of
        Sat m -> satisfies m (CNF 3 [[1, -2], [2, 3]]) `shouldBe` True
        Unsat -> expectationFailure "expected SAT"
    it "solves the clauses split across lines (UNSAT)" $
      solve (CNF 2 [[1, 2], [-1, 2], [-1, -2], [1, -2]]) `shouldBe` Unsat
    it "solves the empty formula" $
      render (solve (CNF 0 [])) `shouldBe` "SAT\n0\n"

  describe "Sat.solve on edge cases" $ do
    it "no clauses: every variable gets a value" $
      render (solve (CNF 3 [])) `shouldSatisfy` (\o -> take 4 o == "SAT\n" && length (words o) == 5)
    it "empty clause is UNSAT" $ solve (CNF 2 [[1], [], [2]]) `shouldBe` Unsat
    it "tautology is satisfied, not stripped" $
      solve (CNF 1 [[1, -1]]) `shouldSatisfy` isSat
    it "contradicting units are UNSAT" $ solve (CNF 1 [[1], [-1]]) `shouldBe` Unsat
    it "unit chain propagates" $
      case solve (CNF 4 [[1], [-1, 2], [-2, 3], [-3, 4]]) of
        Sat m -> modelLiterals m `shouldBe` [1, 2, 3, 4]
        Unsat -> expectationFailure "expected SAT"
    it "handles a single very long clause" $
      solve (CNF 1000 [[1 .. 1000]]) `shouldSatisfy` isSat
    it "falsified-literal removal does not lose clauses" $
      solve (CNF 3 [[-1], [1, 2], [-2, 1, 3], [-3, 1]]) `shouldBe` Unsat

  describe "Sat.solve properties" $ do
    it "agrees with brute force on small random formulas" $ property $
      forAll (genCNF 7 30) $ \cnf -> sound cnf (solve cnf)
    it "agrees with brute force under stress settings (restarts + reduction)" $ property $
      forAll (genCNF 8 40) $ \cnf -> sound cnf (solveWith stress cnf)
    it "default and stress settings agree on 3-SAT near the threshold" $
      withNumTests 30 $ property $
        forAll (rand3 40 170) $ \cnf ->
          let a = solve cnf
              b = solveWith stress cnf
          in isSat a === isSat b .&&. sound' cnf a .&&. sound' cnf b
    it "models cover every variable" $ property $
      forAll (genCNF 7 10) $ \cnf -> case solve cnf of
        Sat m -> length (modelLiterals m) === cnfNumVars cnf
        Unsat -> property True

  describe "Sat.solve on structured instances" $ do
    mapM_ (\h -> it ("pigeonhole " ++ show h ++ " is UNSAT") $
                   solve (pigeonhole h) `shouldBe` Unsat) [2 .. 6]
    it "pigeonhole 6 is UNSAT under stress settings" $
      solveWith stress (pigeonhole 6) `shouldBe` Unsat
    it "as many pigeons as holes is SAT" $
      solve (pigeons' 7 7) `shouldSatisfy` isSat
    it "restarts and clause deletion really happen under stress settings" $ do
      let cnf = pigeonhole 7
          (res, st) = runST $ do
            s <- newSolverWith stress (cnfNumVars cnf)
            mapM_ (addClause s) (cnfClauses cnf)
            ok <- S.solve s
            stats <- solverStats s
            return (ok, stats)
      res `shouldBe` False
      statRestarts st `shouldSatisfy` (> 0)
      statReductions st `shouldSatisfy` (> 0)
  where
    -- soundness check that never calls brute force (instances too large)
    sound' cnf (Sat m) = satisfies m cnf
    sound' _ Unsat = True
