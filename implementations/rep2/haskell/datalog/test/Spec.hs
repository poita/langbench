module Main (main) where

import Data.List (sort)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Test.Hspec
import Test.QuickCheck

import Datalog
import Datalog.Analysis (isSafe, unsafeRules)
import Datalog.Parser (Token (..), tokenize)
import Reference

-- | Run a program and render the output exactly as the CLI does.
cli :: String -> String
cli = either (const "error\n") renderResults . runProgram

main :: IO ()
main = hspec $ do
  parserSpec
  analysisSpec
  orderingSpec
  evalSpec
  cliSpec
  propSpec

parserSpec :: Spec
parserSpec = describe "Datalog.Parser" $ do
  it "parses facts, rules and queries in order" $ do
    let Right p = parseProgram "e(1,a). r(X) :- e(X,_), not f(X), X <= 3. ?- r(X). ?- e(_, _)."
    length (progRules p) `shouldBe` 2
    map atomName (progQueries p) `shouldBe` ["r", "e"]
    ruleBody (progRules p !! 1)
      `shouldBe` [ Pos (Atom "e" [TVar "X", TAnon])
                 , Neg (Atom "f" [TVar "X"])
                 , Cmp OpLe (TVar "X") (TConst (CInt 3))
                 ]
  it "lexes longest match: X<-1 is X, <, -1" $ do
    tokenize "X<-1" `shouldBe` Right [TVariable "X", TCompare OpLt, TInteger (-1)]
  it "treats `not` as a keyword but not_x / nothing as identifiers" $ do
    tokenize "not not_x nothing" `shouldBe` Right [TNot, TIdent "not_x", TIdent "nothing"]
  it "skips comments and arbitrary whitespace" $
    parseProgram "% hi\n\tp(a)\r\n.%x\n" `shouldBe` Right (Program [Rule (Atom "p" [TConst (CSym "a")]) []] [])
  it "accepts the empty program" $
    parseProgram "  % nothing\n" `shouldBe` Right (Program [] [])
  it "rejects malformed input" $
    parseProgram "p(a" `shouldSatisfy` either (const True) (const False)

analysisSpec :: Spec
analysisSpec = describe "Datalog.Analysis" $ do
  let parse = either error id . parseProgram
  it "flags variables only bound by comparisons" $ do
    isSafe (head (progRules (parse "p(Y) :- q(X), X = Y."))) `shouldBe` False
    isSafe (head (progRules (parse "p(X) :- q(X), Y = 5."))) `shouldBe` False
  it "flags anonymous variables in heads, negations and comparisons" $ do
    map isSafe (progRules (parse "p(_) :- q(X). p(X) :- q(X), not r(_). p(X) :- q(X), _ < X."))
      `shouldBe` [False, False, False]
  it "accepts safe rules, including anonymous variables in positive atoms" $
    all isSafe (progRules (parse "p(X) :- q(X, _), not r(X), X != 3. p(a).")) `shouldBe` True
  it "flags facts with variables" $
    unsafeRules (parse "p(X).") `shouldSatisfy` (not . null)
  it "rejects negation through a cycle" $
    check (parse "win(X) :- e(X,Y), not win(Y).") `shouldBe` Left (NotStratifiable (Predicate "win" 1))
  it "rejects negative cycles through several predicates" $
    check (parse "a(X) :- b(X). b(X) :- c(X), not a(X).") `shouldSatisfy` isLeft
  it "allows negative edges between components" $
    check (parse "a(X) :- b(X), not c(X). c(X) :- d(X).") `shouldSatisfy` isRight
  it "orders components after their dependencies" $ do
    let Right comps = check (parse "a(X) :- b(X), not c(X). c(X) :- d(X). b(1).")
        pos q = length (takeWhile (notElem q) comps)
    pos (Predicate "c" 1) `shouldSatisfy` (< pos (Predicate "a" 1))
    pos (Predicate "b" 1) `shouldSatisfy` (< pos (Predicate "a" 1))
  it "treats the same name at different arities as different predicates" $
    check (parse "r(X) :- r(X, Y), not r(Y, Y). r(1, 2).") `shouldSatisfy` isRight
  where
    isLeft = either (const True) (const False)
    isRight = not . isLeft

orderingSpec :: Spec
orderingSpec = describe "constant ordering" $ do
  it "puts integers before identifiers, numerically" $
    sort [CSym "a", CInt 10, CInt (-3), CInt 2] `shouldBe` [CInt (-3), CInt 2, CInt 10, CSym "a"]
  it "orders identifiers like strcmp" $
    sort (map CSym ["ab", "a_b", "aa", "a", "b", "a0", "a_"])
      `shouldBe` map CSym ["a", "a0", "a_", "a_b", "aa", "ab", "b"]

evalSpec :: Spec
evalSpec = describe "evaluation" $ do
  it "computes transitive closure of a cyclic graph" $
    cli (unlines
      [ "edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4)."
      , "path(X, Y) :- edge(X, Y). path(X, Z) :- edge(X, Y), path(Y, Z)."
      , "?- path(1, X). ?- path(4, X). ?- path(X, X)." ])
      `shouldBe` unlines
        [ "path(1, 1)", "path(1, 2)", "path(1, 3)", "path(1, 4)", "-- 4", "-- 0"
        , "path(1, 1)", "path(2, 2)", "path(3, 3)", "-- 3" ]
  it "handles non-linear recursion" $
    cli "l(1,2). l(2,3). l(3,4). l(4,5). l(X,Z) :- l(X,Y), l(Y,Z). ?- l(1, X)."
      `shouldBe` unlines ["l(1, 2)", "l(1, 3)", "l(1, 4)", "l(1, 5)", "-- 4"]
  it "handles mutual recursion with negation above it" $
    cli (unlines
      [ "n(0). n(1). n(2). n(3). n(4). s(0,1). s(1,2). s(2,3). s(3,4)."
      , "even(0). even(Y) :- odd(X), s(X,Y). odd(Y) :- even(X), s(X,Y)."
      , "nodd(X) :- n(X), not odd(X)."
      , "?- nodd(X)." ])
      `shouldBe` unlines ["nodd(0)", "nodd(2)", "nodd(4)", "-- 3"]
  it "evaluates comparisons over the mixed order" $
    cli "n(a). n(b). n(5). n(-2). small(X) :- n(X), X < a. ?- small(X)."
      `shouldBe` unlines ["small(-2)", "small(5)", "-- 2"]
  it "supports rules without positive atoms" $
    cli "p(a) :- 1 < 2. q(a) :- not p(b). r(a) :- 2 < 1. ?- p(X). ?- q(X). ?- r(X)."
      `shouldBe` unlines ["p(a)", "-- 1", "q(a)", "-- 1", "-- 0"]
  it "treats repeated variables in an atom as equality" $
    cli "e(1,1). e(1,2). loop(X) :- e(X,X). ?- loop(X). ?- e(X,X)."
      `shouldBe` unlines ["loop(1)", "-- 1", "e(1, 1)", "-- 1"]
  it "keeps predicates of different arity apart" $
    cli "r(1). r(1,2). ?- r(X). ?- r(X,Y). ?- r(X,Y,Z)."
      `shouldBe` unlines ["r(1)", "-- 1", "r(1, 2)", "-- 1", "-- 0"]
  it "answers queries on undefined predicates with -- 0" $
    cli "?- nothing(X)." `shouldBe` "-- 0\n"
  it "uses a repeated query variable as an equality constraint" $
    cli "e(1,1). e(1,2). e(2,2). ?- e(X, X). ?- e(_, _)."
      `shouldBe` unlines ["e(1, 1)", "e(2, 2)", "-- 2", "e(1, 1)", "e(1, 2)", "e(2, 2)", "-- 3"]
  it "yields the model of a larger chain closure" $ do
    let n = 300 :: Int
        src = concat ["e(" ++ show i ++ "," ++ show (i + 1) ++ "). " | i <- [1 .. n - 1]]
              ++ "p(X,Y) :- e(X,Y). p(X,Z) :- p(X,Y), e(Y,Z). ?- p(1,X)."
    cli src `shouldBe` unlines (["p(1, " ++ show i ++ ")" | i <- [2 .. n]] ++ ["-- " ++ show (n - 1)])

cliSpec :: Spec
cliSpec = describe "error handling" $ do
  it "prints only `error` for an unstratifiable program" $
    cli "edge(1,2). win(X) :- edge(X,Y), not win(Y). ?- win(X)." `shouldBe` "error\n"
  it "prints only `error` for an unsafe rule, even after earlier queries" $
    cli "q(1). ?- q(X). p(X) :- q(Y). ?- p(X)." `shouldBe` "error\n"
  it "prints nothing for a program without queries" $
    cli "p(1). q(X) :- p(X)." `shouldBe` ""
  it "prints nothing for the empty program" $ cli "" `shouldBe` ""

-- Property: agrees with the naive reference on random layered programs ------

predNames :: [String]
predNames = ["p0", "p1", "p2", "p3"]

arityOf :: Int -> Int
arityOf i = 1 + i `mod` 2

levelOf :: Predicate -> Int
levelOf = read . drop 1 . predName

genConst :: Gen Const
genConst = elements [CInt 1, CInt 2, CInt (-1), CSym "a", CSym "b"]

genTermFrom :: [String] -> Gen Term
genTermFrom vs = frequency ([(3, TConst <$> genConst)] ++ [(5, TVar <$> elements vs) | not (null vs)])

genRule :: Gen Rule
genRule = do
  h <- choose (0, 3)
  npos <- choose (0, 3)
  let vars = ["X", "Y", "Z"]
  pos <- vectorOf npos $ do
    i <- choose (0, h)
    Atom (predNames !! i) <$> vectorOf (arityOf i) (frequency [(6, TVar <$> elements vars), (2, TConst <$> genConst), (1, pure TAnon)])
  let bound = S.toList (S.fromList [v | Atom _ ts <- pos, TVar v <- ts])
  negs <- if h == 0 then pure [] else do
    k <- choose (0, 1)
    vectorOf k $ do
      i <- choose (0, h - 1)
      Atom (predNames !! i) <$> vectorOf (arityOf i) (genTermFrom bound)
  cmps <- do
    k <- choose (0, 1)
    vectorOf k (Cmp <$> elements [minBound .. maxBound] <*> genTermFrom bound <*> genTermFrom bound)
  hd <- Atom (predNames !! h) <$> vectorOf (arityOf h) (genTermFrom bound)
  pure (Rule hd (map Pos pos ++ map Neg negs ++ cmps))

genFact :: Gen Rule
genFact = do
  i <- choose (0, 3)
  Rule . Atom (predNames !! i) <$> vectorOf (arityOf i) (TConst <$> genConst) <*> pure []

genProgram :: Gen Program
genProgram = do
  facts <- listOf genFact
  rules <- listOf genRule
  pure (Program (facts ++ rules) [])

propSpec :: Spec
propSpec = describe "properties" $ do
  it "agrees with the naive reference evaluator" $
    withMaxSuccess 500 $ forAll (resize 12 genProgram) $ \prog ->
      let preds = [Predicate n (arityOf i) | (i, n) <- zip [0 ..] predNames]
          expected = referenceModel levelOf prog
      in case solve prog of
           Left e -> counterexample ("rejected: " ++ show e) False
           Right m ->
             conjoin
               [ counterexample (show p) $
                   modelTuples m p === S.toAscList (M.findWithDefault S.empty p expected)
               | p <- preds ]
