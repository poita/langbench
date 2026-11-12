module Main (main) where

import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as BL
import Test.Hspec
import Test.QuickCheck

import Datalog
import qualified Datalog.Trie as T
import qualified GoldenSpec
import Reference

-- | Run program text and return the output as a String.
run :: String -> String
run src = case runSource (B.pack src) of
  Left e -> "parse error: " ++ show e
  Right out -> BL.unpack (BB.toLazyByteString out)

parse :: String -> Program
parse = either (error . show) id . parseProgram . B.pack

sym :: String -> Term
sym = TConst . CSym . B.pack

var :: String -> Term
var = TVar . B.pack

atom :: String -> [Term] -> Atom
atom = Atom . B.pack

main :: IO ()
main = hspec $ do
  describe "Parser" $ do
    it "parses facts, rules and queries" $
      parseProgram (B.pack "p(a, -3). q(X) :- p(X, _), not r(X), X <= 5. ?- q(Y).")
        `shouldBe` Right
          [ ClauseRule (Rule (atom "p" [sym "a", TConst (CInt (-3))]) [])
          , ClauseRule (Rule (atom "q" [var "X"])
              [ Pos (atom "p" [var "X", TAnon]), Neg (atom "r" [var "X"])
              , Cmp OpLe (var "X") (TConst (CInt 5)) ])
          , ClauseQuery (atom "q" [var "Y"]) ]
    it "ignores comments and arbitrary whitespace" $
      parseProgram (B.pack "% c\np(\ta )\r\n.% x\n\n") `shouldBe`
        Right [ClauseRule (Rule (atom "p" [sym "a"]) [])]
    it "lexes longest match: X<-1 is X < -1" $
      parseProgram (B.pack "p(X) :- q(X), X<-1.") `shouldBe`
        Right [ClauseRule (Rule (atom "p" [var "X"])
          [Pos (atom "q" [var "X"]), Cmp OpLt (var "X") (TConst (CInt (-1)))])]
    it "treats identifiers that merely start with 'not' as ordinary" $
      parseProgram (B.pack "p(not_x, nothing).") `shouldBe`
        Right [ClauseRule (Rule (atom "p" [sym "not_x", sym "nothing"]) [])]
    it "accepts the empty program" $ parseProgram (B.pack " % nothing\n") `shouldBe` Right []
    it "rejects a missing period" $ parseProgram (B.pack "p(a)") `shouldSatisfy` isLeft'

  describe "Const ordering" $
    it "puts integers before symbols and uses strcmp order" $ do
      CInt 5 `shouldSatisfy` (< CSym (B.pack "a"))
      CInt (-2) `shouldSatisfy` (< CInt 3)
      map (CSym . B.pack) ["a", "a0", "a_", "a_b", "aa", "ab", "b"] `shouldSatisfy` (\xs -> and (zipWith (<) xs (drop 1 xs)))

  describe "Safety and stratification" $ do
    it "rejects head variables not bound positively" $
      run "q(1).\n?- q(X).\np(X) :- q(Y).\n?- p(X).\n" `shouldBe` "error\n"
    it "rejects comparisons that would bind" $ do
      run "q(1). p(Y) :- q(X), X = Y. ?- p(X)." `shouldBe` "error\n"
      run "q(1). p(X) :- q(X), Y = 5. ?- p(X)." `shouldBe` "error\n"
    it "rejects '_' in negated atoms, heads and comparisons" $ do
      run "q(1). p(X) :- q(X), not q(_)." `shouldBe` "error\n"
      run "q(1). p(_) :- q(1)." `shouldBe` "error\n"
      run "q(1). p(X) :- q(X), _ < 3." `shouldBe` "error\n"
    it "rejects non-ground facts" $ run "p(X)." `shouldBe` "error\n"
    it "rejects negative cycles" $ do
      run "edge(1,2). win(X) :- edge(X,Y), not win(Y). ?- win(X)." `shouldBe` "error\n"
      run "a(X) :- b(X), not c(X). c(X) :- d(X), a(X). b(1). d(1)." `shouldBe` "error\n"
    it "accepts positive cycles through negation of a lower stratum" $
      run "n(1). n(2). e(1). p(X) :- n(X), not e(X). p(X) :- p(X). ?- p(X)."
        `shouldBe` "p(2)\n-- 1\n"
    it "orders components topologically" $ do
      let prog = parse "b(X) :- a(X). c(X) :- b(X), not a(X). a(1)."
      fmap (map compPreds) (stratify (clauseRules prog))
        `shouldBe` Right [[(B.pack "a", 1)], [(B.pack "b", 1)], [(B.pack "c", 1)]]
    it "treats predicates of different arity as different predicates" $
      run "r(1). q(X) :- r(X, X). ?- r(X). ?- r(X, Y). ?- q(X)."
        `shouldBe` "r(1)\n-- 1\n-- 0\n-- 0\n"

  describe "Evaluation (examples from the specification)" $ do
    it "computes a transitive closure" $
      run (unlines
        [ "edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4)."
        , "path(X, Y) :- edge(X, Y)."
        , "path(X, Z) :- edge(X, Y), path(Y, Z)."
        , "?- path(1, X). ?- path(4, X). ?- path(X, X)." ])
        `shouldBe` unlines
          [ "path(1, 1)", "path(1, 2)", "path(1, 3)", "path(1, 4)", "-- 4", "-- 0"
          , "path(1, 1)", "path(2, 2)", "path(3, 3)", "-- 3" ]
    it "handles negation, comparisons and mixed constants" $
      run (unlines
        [ "node(a). node(b). node(c). node(5). node(-2)."
        , "link(a, b). link(b, 5). link(5, 5)."
        , "reach(X, Y) :- link(X, Y)."
        , "reach(X, Z) :- reach(X, Y), link(Y, Z)."
        , "sink(X) :- node(X), not hasout(X)."
        , "hasout(X) :- link(X, _)."
        , "small(X) :- node(X), X < a."
        , "?- sink(X). ?- small(X). ?- reach(a, X). ?- reach(X, X)." ])
        `shouldBe` unlines
          [ "sink(-2)", "sink(c)", "-- 2", "small(-2)", "small(5)", "-- 2"
          , "reach(a, 5)", "reach(a, b)", "-- 2", "reach(5, 5)", "-- 1" ]
    it "handles non-linear recursion in every recursive position" $
      run (unlines
        [ "link(1,2). link(2,3). link(3,4). link(4,5)."
        , "link(X, Z) :- link(X, Y), link(Y, Z)."
        , "?- link(1, X)." ])
        `shouldBe` unlines ["link(1, 2)", "link(1, 3)", "link(1, 4)", "link(1, 5)", "-- 4"]
    it "handles mutual recursion" $
      run (unlines
        [ "succ(0,1). succ(1,2). succ(2,3). succ(3,4)."
        , "even(0)."
        , "odd(Y) :- even(X), succ(X, Y)."
        , "even(Y) :- odd(X), succ(X, Y)."
        , "?- even(X). ?- odd(X)." ])
        `shouldBe` unlines ["even(0)", "even(2)", "even(4)", "-- 3", "odd(1)", "odd(3)", "-- 2"]
    it "produces no output for a program without queries" $ run "p(1). p(X) :- p(X)." `shouldBe` ""
    it "answers queries in source order, wherever the facts are" $
      run "?- p(X). p(1). ?- p(1). p(2)." `shouldBe` "p(1)\np(2)\n-- 2\np(1)\n-- 1\n"
    it "matches repeated variables and anonymous variables in queries" $
      run "e(1,1). e(1,2). e(2,2). ?- e(X,X). ?- e(_,_). ?- e(_, 2). ?- missing(X)."
        `shouldBe` "e(1, 1)\ne(2, 2)\n-- 2\ne(1, 1)\ne(1, 2)\ne(2, 2)\n-- 3\ne(1, 2)\ne(2, 2)\n-- 2\n-- 0\n"
    it "supports ground rules and constant comparisons" $
      run "p(1) :- 1 < 2. q(1) :- 2 < 1. r(1) :- not q(1). ?- p(X). ?- q(X). ?- r(X)."
        `shouldBe` "p(1)\n-- 1\n-- 0\nr(1)\n-- 1\n"
    it "compares integers with symbols by the total order" $
      run "v(5). v(abc). v(-1). lt(X, Y) :- v(X), v(Y), X < Y. ?- lt(X, Y)."
        `shouldBe` "lt(-1, 5)\nlt(-1, abc)\nlt(5, abc)\n-- 3\n"
    it "supports repeated variables within a body atom" $
      run "e(1,1). e(1,2). loop(X) :- e(X, X). ?- loop(X)." `shouldBe` "loop(1)\n-- 1\n"

  describe "Public API" $ do
    it "evaluates and queries a model" $ do
      let prog = parse "e(1,2). e(2,3). t(X,Y) :- e(X,Y). t(X,Z) :- e(X,Y), t(Y,Z)."
      model <- either (\e -> fail (show e)) pure (evaluate prog)
      queryModel model (atom "t" [TConst (CInt 1), var "X"]) `shouldBe` [[CInt 1, CInt 2], [CInt 1, CInt 3]]
      queryModel model (atom "t" [sym "unknown", var "X"]) `shouldBe` []
      relationTuples model (B.pack "e", 2) `shouldBe` [[CInt 1, CInt 2], [CInt 2, CInt 3]]
    it "reports the reason for rejection" $ do
      case evaluate (parse "p(X) :- q(Y).") of
        Left (UnsafeRule r) -> ruleHead r `shouldBe` atom "p" [var "X"]
        _ -> expectationFailure "expected UnsafeRule"
      case evaluate (parse "p(X) :- q(X), not p(X).") of
        Left (NotStratifiable k) -> k `shouldBe` (B.pack "p", 1)
        _ -> expectationFailure "expected NotStratifiable"

  describe "Trie" $ do
    it "behaves like a set of tuples" $
      property $ \(xs :: [(Digit, Digit, Digit)]) ->
        let ts = [[a, b, c] | (Digit a, Digit b, Digit c) <- xs]
            t = T.fromList 3 ts
         in T.toList t == uniqSorted ts && all (`T.member` t) ts && T.size t == length (uniqSorted ts)
    it "union is set union" $
      property $ \(xs :: [(Digit, Digit)]) (ys :: [(Digit, Digit)]) ->
        let f zs = [[a, b] | (Digit a, Digit b) <- zs]
         in T.toList (T.union (T.fromList 2 (f xs)) (T.fromList 2 (f ys))) == uniqSorted (f xs ++ f ys)

  describe "Random programs" $ do
    it "print/parse round-trips" $
      forAll genProgram $ \p -> parseProgram (renderProgram p) === Right p
    it "agree with the naive reference evaluator" $
      withNumTests 1500 $ forAll genProgram $ \p ->
        let expected = referenceRun p
            actual = case evaluate p of
              Left _ -> Nothing
              Right m -> Just [queryModel m q | q <- clauseQueries p]
         in counterexample (B.unpack (renderProgram p)) (actual === expected)
    it "sometimes yield a model and sometimes an error" $
      forAll (vectorOf 200 genProgram) $ \ps ->
        let ok = length [() | p <- ps, Right _ <- [evaluate p]]
         in ok > 20 && ok < 190

  describe "Golden programs" GoldenSpec.spec

isLeft' :: Either a b -> Bool
isLeft' = either (const True) (const False)

newtype Digit = Digit Int deriving Show

instance Arbitrary Digit where
  arbitrary = Digit <$> choose (0, 6)

uniqSorted :: [[Int]] -> [[Int]]
uniqSorted = foldr ins [] . foldr ins []
  where
    ins x [] = [x]
    ins x (y : ys) = case compare x y of
      LT -> x : y : ys
      EQ -> y : ys
      GT -> y : ins x ys

------------------------------------------------------------------------------
-- Random programs over predicates p0, p1 (arity 1) and p2, p3 (arity 2)

genProgram :: Gen Program
genProgram = do
  nf <- choose (0, 12)
  nr <- choose (0, 6)
  nq <- choose (1, 3)
  facts <- vectorOf nf (ClauseRule . (`Rule` []) <$> genGround)
  rules <- vectorOf nr (ClauseRule <$> genRule)
  queries <- vectorOf nq (ClauseQuery <$> genQuery)
  shuffle (facts ++ rules ++ queries)

predArity :: Int -> Int
predArity i = if i < 2 then 1 else 2

genConst :: Gen Const
genConst = frequency
  [ (3, CInt <$> elements [-1, 0, 1, 2])
  , (3, CSym . B.pack <$> elements ["a", "b", "ab"]) ]

genPred :: Gen (String, Int)
genPred = do
  i <- choose (0, 3)
  pure ("p" ++ show i, predArity i)

genGround :: Gen Atom
genGround = do
  (n, k) <- genPred
  Atom (B.pack n) <$> vectorOf k (TConst <$> genConst)

vars :: [Term]
vars = map var ["X", "Y", "Z"]

genQuery :: Gen Atom
genQuery = do
  (n, k) <- genPred
  Atom (B.pack n) <$> vectorOf k (frequency [(2, TConst <$> genConst), (3, elements vars), (1, pure TAnon)])

genRule :: Gen Rule
genRule = do
  npos <- choose (1, 3)
  pos <- vectorOf npos $ do
    (n, k) <- genPred
    Atom (B.pack n) <$> vectorOf k (frequency [(5, elements vars), (1, TConst <$> genConst), (1, pure TAnon)])
  let bound = [t | a <- pos, t@(TVar _) <- atomArgs a]
      pick = if null bound then elements vars else frequency [(9, elements bound), (1, elements vars)]
  nneg <- frequency [(3, pure 0), (2, pure 1)]
  negs <- vectorOf nneg $ do
    (n, k) <- genPred
    Neg . Atom (B.pack n) <$> vectorOf k (frequency [(8, pick), (1, TConst <$> genConst)])
  ncmp <- frequency [(3, pure 0), (2, pure 1)]
  cmps <- vectorOf ncmp $ do
    op <- elements [OpLt, OpLe, OpGt, OpGe, OpEq, OpNe]
    l <- pick
    r <- frequency [(2, pick), (2, TConst <$> genConst)]
    pure (Cmp op l r)
  (hn, hk) <- genPred
  hd <- Atom (B.pack hn) <$> vectorOf hk (frequency [(9, pick), (2, TConst <$> genConst)])
  body <- shuffle (map Pos pos ++ negs ++ cmps)
  pure (Rule hd body)
