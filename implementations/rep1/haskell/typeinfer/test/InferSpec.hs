module InferSpec (spec) where

import Test.Hspec
import Test.QuickCheck

import Generators
import Language.TypeInfer

-- | Run a program and return the CLI output lines.
run :: String -> [String]
run src = either (\e -> [renderParseError e]) (map renderResult) (inferSource src)

-- | The line for a single bare expression.
ty :: String -> String
ty src = case run ("(" ++ src ++ ");;") of
  [l] -> l
  ls -> "unexpected output: " ++ show ls

spec :: Spec
spec = do
  describe "spec examples" $ do
    it "example 1" $
      run (unlines
        [ "let id = fun x -> x;;"
        , "let compose f g x = f (g x);;"
        , "compose;;"
        , "let rec len l = if null l then 0 else 1 + len (tl l);;"
        , "(id 1, id true, len [true]);;"
        , "fun f -> (f 1, f true);;" ])
      `shouldBe`
        [ "id : 'a -> 'a"
        , "compose : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b"
        , "- : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b"
        , "len : 'a list -> int"
        , "- : int * bool * int"
        , "error: unify" ]
    it "example 2" $
      run (unlines
        [ "let succ n = fun f x -> f (n f x);;"
        , "let add m n = fun f x -> m f (n f x);;"
        , "fun x -> x x;;"
        , "let g = id id;;"
        , "let id = fun x -> x;;"
        , "let g = id id;;"
        , "(g 1, g true);;"
        , "[fun p -> (snd p, fst p)];;" ])
      `shouldBe`
        [ "succ : (('a -> 'b) -> 'c -> 'a) -> ('a -> 'b) -> 'c -> 'b"
        , "add : ('a -> 'b -> 'c) -> ('a -> 'd -> 'b) -> 'a -> 'd -> 'c"
        , "error: occurs"
        , "error: unbound"
        , "id : 'a -> 'a"
        , "g : 'a -> 'a"
        , "- : int * bool"
        , "- : ('a * 'b -> 'b * 'a) list" ]
    it "example 3" $
      run (unlines
        [ "let map = 3;;"
        , "map;;"
        , "fun a b c -> let p = (a, b) in (fun x -> [x; c], p, fst p);;"
        , "let rec bad x = bad 1 + bad true;;"
        , "1 :: [true];;" ])
      `shouldBe`
        [ "map : int"
        , "- : int"
        , "- : 'a -> 'b -> 'c -> ('c -> 'c list) * ('a * 'b) * 'a"
        , "error: unify"
        , "error: unify" ]

  describe "literals and built-ins" $ do
    it "types literals" $ do
      ty "1" `shouldBe` "- : int"
      ty "true" `shouldBe` "- : bool"
      ty "()" `shouldBe` "- : unit"
      ty "[]" `shouldBe` "- : 'a list"
    it "has the documented built-ins" $
      mapM_ (\(n, t) -> ty n `shouldBe` "- : " ++ renderType t) builtinTypes
    it "allows built-ins to be partially applied and shadowed" $ do
      ty "map not" `shouldBe` "- : bool list -> bool list"
      run "let hd = 1;; hd;;" `shouldBe` ["hd : int", "- : int"]

  describe "polymorphism" $ do
    it "generalises every let, with no value restriction" $
      ty "let id = fun x -> x in let g = id id in (g 1, g true)" `shouldBe` "- : int * bool"
    it "keeps lambda-bound variables monomorphic" $
      ty "fun f -> (f 1, f true)" `shouldBe` "error: unify"
    it "does not generalise variables free in the environment" $
      ty "fun x -> let y = x in (y 1, y true)" `shouldBe` "error: unify"
    it "keeps recursive functions monomorphic in their own body" $ do
      ty "let rec f x = f 1 + f true in f" `shouldBe` "error: unify"
      ty "let rec f x = x in (f 1, f true)" `shouldBe` "- : int * bool"
    it "does not let a non-recursive let see its own name" $ do
      ty "let x = x + 1 in x" `shouldBe` "error: unbound"
      run "let x = true;; let x = x + 1;; x;;" `shouldBe`
        ["x : bool", "error: unify", "- : bool"]

  describe "errors" $ do
    it "detects infinite types" $ do
      ty "fun x -> x x" `shouldBe` "error: occurs"
      ty "fun x -> [x; [x]]" `shouldBe` "error: occurs"
    it "reports unbound variables" $
      ty "nope" `shouldBe` "error: unbound"
    it "distinguishes tuple arities and nesting" $ do
      ty "if true then (1, 2) else (1, 2, 3)" `shouldBe` "error: unify"
      ty "if true then (1, 2, 3) else ((1, 2), 3)" `shouldBe` "error: unify"
    it "does not make comparison polymorphic" $
      ty "true = false" `shouldBe` "error: unify"
    it "reports the first problem in inference order" $ do
      ty "fun x -> if true then (x, 0) else ([x], true)" `shouldBe` "error: occurs"
      ty "true + undefined" `shouldBe` "error: unify"
      ty "undefined + true" `shouldBe` "error: unbound"
      ty "if 1 then undefined else 2" `shouldBe` "error: unify"
      ty "if true then 1 else undefined" `shouldBe` "error: unbound"
    it "leaves the environment unchanged after a failed declaration" $
      run "let x = 1;; let x = x x;; x;; let y = z;; y;;" `shouldBe`
        ["x : int", "error: unify", "- : int", "error: unbound", "error: unbound"]

  describe "printing" $ do
    it "renames variables per declaration in order of appearance" $
      run "let f a b = (b, a);; let g x y z = z;;" `shouldBe`
        ["f : 'a -> 'b -> 'b * 'a", "g : 'a -> 'b -> 'c -> 'c"]
    it "continues numbering past z" $ do
      let params = [ [c] | c <- ['a' .. 'z'] ] ++ ["a1", "b1"]
          src = "fun " ++ unwords params ++ " -> (" ++ concatMap (++ ", ") (init params) ++ last params ++ ")"
      ty src `shouldSatisfy` (\l -> "'z -> 'a1 -> 'b1 -> 'a * 'b" `isInfixOf'` l
                                    && "'z1" `notIn` l)

  describe "scale" $ do
    it "handles a deep chain of nested lets" $ do
      let n = 3000 :: Int
          src = "fun z -> " ++ concat [ "let a" ++ show i ++ " = " ++ prev i ++ " in " | i <- [1 .. n] ]
                ++ "a" ++ show n ++ ";;"
          prev i = if i == 1 then "z" else "(a" ++ show (i - 1) ++ ", 1)"
      length (run src) `shouldBe` 1
      take 1 (run src) `shouldSatisfy` all (\l -> take 8 l == "- : 'a -")
    it "does not expand shared types exponentially during unification" $ do
      -- p25 has 2^25 leaves when unfolded but only 25 distinct nodes; the two
      -- instances below are equal but distinct graphs.
      let src = unlines $
            [ "let pair x = (x, x);;", "let p0 = fun x -> x;;" ] ++
            [ "let p" ++ show (i + 1 :: Int) ++ " = pair p" ++ show i ++ ";;" | i <- [0 .. 24] ] ++
            [ "fun a -> if true then (p25, a) else (p25, p25);;" ]
      -- Only inspect success/failure: printing would produce 2^25 leaves.
      fmap (map (either (const False) (const True) . resultType)) (inferSource src)
        `shouldBe` Right (replicate 28 True)
    it "handles an application with 5000 arguments" $
      let src = "fun f -> f" ++ concat (replicate 5000 " 1") ++ ";;"
      in run src `shouldBe` ["- : (" ++ concat (replicate 5000 "int -> ") ++ "'a) -> 'a"]

  describe "properties" $ do
    it "let x = e in x has the type of e" $
      property $ forAll genExpr $ \e ->
        inferExpr (ELet "x" e (EVar "x")) === inferExpr e
    it "inferred types are canonically numbered" $
      property $ forAll genExpr $ \e -> case inferExpr e of
        Right t -> freeVars t === [0 .. length (freeVars t) - 1]
        Left _ -> property True
    it "never lets a failed declaration affect later ones" $
      property $ forAll genProgram $ \p ->
        let failing = [ d | (d, r) <- zip p (inferProgram p), isLeft' (resultType r) ]
        in all (\d -> inferProgram (d : p) !! 0 == inferProgram [d] !! 0) failing
  where
    isLeft' = either (const True) (const False)
    isInfixOf' needle hay = any (\k -> take (length needle) (drop k hay) == needle) [0 .. length hay]
    notIn needle hay = not (isInfixOf' needle hay)
