module Main (main) where

import Control.Monad.ST (runST)
import Data.Array.Unboxed (listArray)
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Bits (testBit)
import Test.Hspec
import Test.QuickCheck hiding (Result, Small)

import Sat
import qualified Sat.Solver as S

-- | Is the result a model of the formula (and of the right shape)?
isModelOf :: CNF -> Result -> Bool
isModelOf cnf (Satisfiable m) = length (modelLiterals m) == cnfNumVars cnf && satisfies m cnf
isModelOf _ Unsatisfiable = False

isSat :: Result -> Bool
isSat (Satisfiable _) = True
isSat Unsatisfiable = False

-- | Exhaustive satisfiability check for small formulas.
bruteForce :: CNF -> Bool
bruteForce (CNF n cs) = any ok [0 .. 2 ^ n - 1 :: Int]
  where
    ok bits = all (any (holds bits)) cs
    holds bits l = if l > 0 then testBit bits (l - 1) else not (testBit bits (negate l - 1))

-- | Pigeonhole: @n+1@ pigeons into @n@ holes (unsatisfiable).
pigeonhole :: Int -> CNF
pigeonhole n = CNF ((n + 1) * n) (pigeons ++ holes)
  where
    v p h = p * n + h + 1
    pigeons = [[v p h | h <- [0 .. n - 1]] | p <- [0 .. n]]
    holes = [[negate (v p h), negate (v q h)] | h <- [0 .. n - 1], p <- [0 .. n], q <- [p + 1 .. n]]

-- | Deterministic pseudo-random 3-SAT (LCG), for reproducible hard instances.
random3Sat :: Int -> Int -> Int -> CNF
random3Sat seed n m = CNF n (take m (go (seed * 2654435761 + 12345)))
  where
    next x = (x * 6364136223846793005 + 1442695040888963407) `mod` (2 ^ (62 :: Int))
    go x0 =
      let (c, x') = foldl' pick ([], x0) [1 :: Int .. 3]
      in c : go x'
    pick (acc, x) _ =
      let x1 = next x
          x2 = next x1
          v = (x1 `div` 65536) `mod` n + 1
          sgn = if even (x2 `div` 65536) then 1 else -1
      in (sgn * v : acc, x2)

-- | SmallCNF arbitrary formulas, including empty clauses, repeats and tautologies.
newtype SmallCNF = SmallCNF CNF deriving Show

instance Arbitrary SmallCNF where
  arbitrary = do
    n <- chooseInt (0, 8)
    m <- chooseInt (0, 30)
    cs <- vectorOf m $ do
      k <- chooseInt (0, if n == 0 then 0 else 4)
      vectorOf k $ do
        v <- chooseInt (1, n)
        b <- arbitrary
        return (if b then v else negate v)
    return (SmallCNF (CNF n cs))
  shrink (SmallCNF (CNF n cs)) =
    [SmallCNF (CNF n cs') | cs' <- shrinkList (const []) cs]

parse :: String -> Either String CNF
parse = parseDimacs . BS.pack

render :: Result -> String
render = BL.unpack . B.toLazyByteString . renderResult

main :: IO ()
main = hspec $ do
  describe "Sat.Dimacs.parseDimacs" $ do
    it "reads a simple formula" $
      parse "p cnf 3 2\n1 -2 0\n2 3 0\n" `shouldBe` Right (CNF 3 [[1, -2], [2, 3]])
    it "ignores comments, blank lines and surrounding blanks" $
      parse "c hi\n\n  \t p cnf 2 1\ncfoo\n \t1 -2 0 \nc\n"
        `shouldBe` Right (CNF 2 [[1, -2]])
    it "allows clauses split over lines and several per line" $
      parse "p cnf 2 4\n1 2\n0 -1 2 0\n-1 -2 0 1 -2 0"
        `shouldBe` Right (CNF 2 [[1, 2], [-1, 2], [-1, -2], [1, -2]])
    it "interleaves comments with the numbers of a clause" $
      parse "p cnf 3 1\n1 2\nc interrupt\n  3 0\nc tail\n" `shouldBe` Right (CNF 3 [[1, 2, 3]])
    it "keeps empty clauses, repeats and tautologies" $
      parse "p cnf 2 3\n0\n1 1 -2 0\n1 -1 0\n"
        `shouldBe` Right (CNF 2 [[], [1, 1, -2], [1, -1]])
    it "accepts an empty formula" $ parse "p cnf 0 0" `shouldBe` Right (CNF 0 [])
    it "rejects a missing header" $ parse "1 2 0\n" `shouldSatisfy` isLeft'
    it "rejects an unterminated clause" $ parse "p cnf 2 1\n1 2\n" `shouldSatisfy` isLeft'
    it "rejects a literal out of range" $ parse "p cnf 2 1\n3 0\n" `shouldSatisfy` isLeft'
    it "rejects a wrong clause count" $ parse "p cnf 2 2\n1 0\n" `shouldSatisfy` isLeft'

  describe "Sat.Dimacs.renderResult" $ do
    it "prints UNSAT" $ render Unsatisfiable `shouldBe` "UNSAT\n"
    it "prints a model with a trailing 0" $
      render (Satisfiable (listArray (1, 3) [True, False, True])) `shouldBe` "SAT\n1 -2 3 0\n"
    it "prints just 0 for zero variables" $
      render (Satisfiable (listArray (1, 0) [])) `shouldBe` "SAT\n0\n"

  describe "Sat.solve" $ do
    it "accepts the empty formula" $ solve (CNF 0 []) `shouldSatisfy` isSat
    it "assigns every variable when there are no clauses" $
      solve (CNF 5 []) `shouldSatisfy` isModelOf (CNF 5 [])
    it "rejects an empty clause" $ solve (CNF 3 [[1, 2], []]) `shouldBe` Unsatisfiable
    it "rejects contradictory units" $ solve (CNF 1 [[1], [-1]]) `shouldBe` Unsatisfiable
    it "propagates a unit chain" $ do
      let cnf = CNF 4 [[1], [-1, 2], [-2, 3], [-3, 4]]
      solve cnf `shouldSatisfy` isModelOf cnf
    it "treats a tautology as satisfied" $ do
      let cnf = CNF 2 [[1, -1], [2], [-2, -2, 2]]
      solve cnf `shouldSatisfy` isModelOf cnf
    it "handles all eight clauses on three variables (UNSAT)" $
      solve (CNF 3 [[a, b, c] | a <- [1, -1], b <- [2, -2], c <- [3, -3]])
        `shouldBe` Unsatisfiable
    it "handles a 1000-literal clause" $ do
      let cnf = CNF 1000 [[1 .. 1000], [-1], [-2]]
      solve cnf `shouldSatisfy` isModelOf cnf
    it "refutes pigeonhole formulas" $
      mapM_ (\n -> solve (pigeonhole n) `shouldBe` Unsatisfiable) [1 .. 7]
    it "refutes PHP(8) (exercises restarts and clause deletion)" $
      solve (pigeonhole 8) `shouldBe` Unsatisfiable
    it "solves random 3-SAT near the threshold, with correct models" $
      mapM_ (\seed -> do
               let cnf = random3Sat seed 120 511
               case solve cnf of
                 Satisfiable m -> (m `satisfies` cnf) `shouldBe` True
                 Unsatisfiable -> return ())
            [1 .. 12]
    it "agrees with brute force on random formulas" $
      property $ \(SmallCNF cnf) ->
        case solve cnf of
          Satisfiable m -> satisfies m cnf
          Unsatisfiable -> not (bruteForce cnf)

  describe "Sat.solve on structured random formulas" $
    it "agrees with brute force on 3-SAT at the threshold (learning is exercised)" $
      mapM_ (\seed -> do
               let cnf = random3Sat seed 14 60
               isSat (solve cnf) `shouldBe` bruteForce cnf)
            [1 .. 60]

  describe "Sat.Solver imperative interface" $ do
    it "reports a root conflict from addClause" $
      runST (do s <- S.newSolver 2
                a <- S.addClause s [1]
                b <- S.addClause s [-1, 2]
                c <- S.addClause s [-2]
                return (a, b, c))
        `shouldBe` (True, True, False)
    it "solves what was added" $
      runST (do s <- S.newSolver 2
                _ <- S.addClause s [1, 2]
                _ <- S.addClause s [-1]
                S.solveSolver s)
        `shouldSatisfy` isModelOf (CNF 2 [[1, 2], [-1]])

  describe "end to end" $
    it "parses, solves and renders" $ do
      let out = either error (render . solve) (parse "p cnf 2 4\n1 2\n0 -1 2 0\n-1 -2 0 1 -2 0\n")
      out `shouldBe` "UNSAT\n"
  where
    isLeft' = either (const True) (const False)
