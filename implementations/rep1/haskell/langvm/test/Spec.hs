module Main (main) where

import Control.Monad (forM_)
import Data.IORef (modifyIORef, newIORef, readIORef)
import Data.List (isSuffixOf, nub, sort, sortBy)
import Data.Ord (comparing)
import Numeric (floatToDigits)
import System.Directory (listDirectory)
import Test.Hspec
import Test.QuickCheck

import Langvm
import Langvm.Lexer
import Langvm.Number
import Langvm.Source

-- Helpers -------------------------------------------------------------------------

-- | A one-module program whose @main@ has the given body.
prog :: [String] -> String
prog body = unlines (["@module main", "fn main() {"] ++ map ("    " ++) body ++ ["}"])

-- | The first diagnostic line (without the newline) of an input.
diagnose :: String -> IO String
diagnose input = takeWhile (/= '\n') <$> executeText input

-- | Whitespace at line ends and at the end of the text does not matter.
normalise :: String -> String
normalise = unlines . map (reverse . dropWhile (== ' ') . reverse) . lines

-- Properties -------------------------------------------------------------------------

-- | Integer expressions with the evaluation order and wrapping of Vellum.
data E
  = Lit Int
  | Neg E
  | Not E
  | Bin String E E
  | Shift String E Int
  deriving (Show)

instance Arbitrary E where
  arbitrary = sized gen
    where
      gen 0 = Lit <$> oneof [choose (0, 1000), choose (0, maxBound), elements [0, 1, 2, 63, maxBound]]
      gen n = frequency
        [ (2, gen 0)
        , (1, Neg <$> gen (n - 1))
        , (1, Not <$> gen (n - 1))
        , (6, Bin <$> elements ["+", "-", "*", "/", "%", "&", "|", "^"] <*> gen (n `div` 2) <*> gen (n `div` 2))
        , (1, Shift <$> elements ["<<", ">>"] <*> gen (n - 1) <*> choose (0, 66))
        ]
  shrink e = case e of
    Neg a -> a : [Neg a' | a' <- shrink a]
    Not a -> a : [Not a' | a' <- shrink a]
    Bin o a b -> a : b : [Bin o a' b | a' <- shrink a] ++ [Bin o a b' | b' <- shrink b]
    Shift o a k -> a : [Shift o a' k | a' <- shrink a]
    Lit n -> [Lit m | m <- shrink n, m >= 0]

-- | The Vellum precedence level of an operator (section 4.4).
level :: String -> Int
level o = case o of
  "|" -> 4; "^" -> 5; "&" -> 6; "<<" -> 7; ">>" -> 7
  "+" -> 8; "-" -> 8; "*" -> 9; "/" -> 9; "%" -> 9
  _ -> 0

-- | Render with only the parentheses that precedence requires.
render :: Int -> E -> String
render _ (Lit n) = show n
render _ (Neg e) = "-" ++ paren (needsParen e) (render 10 e)
render _ (Not e) = "~" ++ paren (needsParen e) (render 10 e)
render p (Bin o a b) =
  let l = level o
  in paren (l < p) (render l a ++ " " ++ o ++ " " ++ render (l + 1) b)
render p (Shift o a k) =
  let l = level o in paren (l < p) (render l a ++ " " ++ o ++ " " ++ show k)

needsParen :: E -> Bool
needsParen e = case e of
  Lit _ -> False
  Neg _ -> False
  Not _ -> False
  _ -> True

paren :: Bool -> String -> String
paren True s = "(" ++ s ++ ")"
paren False s = s

eval :: E -> Either String Int
eval e = case e of
  Lit n -> Right n
  Neg a -> negate <$> eval a
  Not a -> (\x -> -x - 1) <$> eval a
  Shift o a k -> do
    x <- eval a
    if k > 63 then Left "shift amount out of range"
    else Right (if o == "<<" then shiftLWrap x k else fromInteger (toInteger x `div` 2 ^ k))
  Bin o a b -> do
    x <- eval a
    y <- eval b
    case o of
      "+" -> Right (x + y)
      "-" -> Right (x - y)
      "*" -> Right (x * y)
      "/" | y == 0 -> Left "divide by zero"
          | y == -1 -> Right (negate x)
          | otherwise -> Right (x `quot` y)
      "%" | y == 0 -> Left "modulo by zero"
          | y == -1 -> Right 0
          | otherwise -> Right (x `rem` y)
      "&" -> Right (andI x y)
      "|" -> Right (orI x y)
      _ -> Right (xorI x y)
  where
    shiftLWrap x k = fromInteger ((toInteger x * 2 ^ k) `mod` 2 ^ (64 :: Int) `wrap` ())
    wrap v () = if v >= 2 ^ (63 :: Int) then v - 2 ^ (64 :: Int) else v

-- Bitwise operations through Integer, to keep the model independent of the VM.
andI, orI, xorI :: Int -> Int -> Int
andI = bitop (\a b -> a && b)
orI = bitop (||)
xorI = bitop (/=)

bitop :: (Bool -> Bool -> Bool) -> Int -> Int -> Int
bitop f x y = fromBits [f (bit' x i) (bit' y i) | i <- [0 .. 63]]
  where
    bit' v i = odd ((toInteger v `mod` 2 ^ (64 :: Int)) `div` 2 ^ i)
    fromBits bs =
      let u = sum [2 ^ i | (i, True) <- zip [0 :: Int ..] bs] :: Integer
      in fromInteger (if u >= 2 ^ (63 :: Int) then u - 2 ^ (64 :: Int) else u)

prop_arith :: E -> Property
prop_arith e = ioProperty $ do
  out <- executeText (prog ["print(showInt(" ++ render 0 e ++ "));"])
  return $ out === case eval e of
    Right n -> show n ++ "\n"
    Left msg -> "panic: " ++ msg ++ "\n"

prop_sortStable :: [Int] -> Property
prop_sortStable xs0 = ioProperty $ do
  let xs = map (`mod` 100) xs0
      lit = "[" ++ commaSep (map show xs) ++ "]"
      body = [ "let xs: [Int] = " ++ lit ++ ";"
             , "let ys = sortBy(xs, |a, b| cmpI(a % 10, b % 10));"
             , "print(strJoin(listMap(ys, |v| showInt(v)), \",\"));" ]
      expected = commaSep (map show (sortBy (comparing (`mod` 10)) xs))
  out <- executeText (prog body)
  return (out === expected ++ "\n")

commaSep :: [String] -> String
commaSep [] = ""
commaSep [x] = x
commaSep (x : r) = x ++ "," ++ commaSep r

data MapOp = Set Int Int | Del Int
  deriving (Show)

instance Arbitrary MapOp where
  arbitrary = frequency [(3, Set <$> key <*> choose (0, 99)), (2, Del <$> key)]
    where key = frequency [(3, choose (0, 12)), (1, choose (0, 300))]

-- | The insertion-ordered map against a plain association list.
prop_mapModel :: [MapOp] -> Property
prop_mapModel ops = ioProperty $ do
  let body = ["var m: #[Int: Int] = mapNew();"]
             ++ map stmt ops
             ++ [ "for (k, v) in pairsOf(m) { emit(showInt(k) ++ \"=\" ++ showInt(v) ++ \" \"); }"
                , "print(showInt(mapLen(m)));" ]
      stmt (Set k v) = "m[" ++ show k ++ "] = " ++ show v ++ ";"
      stmt (Del k) = "mapDel(m, " ++ show k ++ ");"
      model = foldl step [] ops
      step acc (Set k v)
        | k `elem` map fst acc = [(k', if k' == k then v else v') | (k', v') <- acc]
        | otherwise = acc ++ [(k, v)]
      step acc (Del k) = filter ((/= k) . fst) acc
      expected = concat [show k ++ "=" ++ show v ++ " " | (k, v) <- model] ++ show (length model) ++ "\n"
  out <- executeText (prog body)
  return (out === expected)

prop_splitJoin :: [Bool] -> NonEmptyList Bool -> Property
prop_splitJoin cs sep = ioProperty $ do
  let ch b = if b then 'a' else ','
      s = map ch cs
      sp = map ch (getNonEmpty sep)
      body = ["print(showBool(strJoin(strSplit(\"" ++ s ++ "\", \"" ++ sp ++ "\"), \"" ++ sp ++ "\") == \"" ++ s ++ "\"));"]
  out <- executeText (prog body)
  return (out === "true\n")

-- | @showFixed d x@ is within half a unit of the last place of @x@ (exactly).
prop_showFixedClose :: Double -> Int -> Property
prop_showFixedClose x0 dRaw =
  let d = dRaw `mod` 18
      x = if isNaN x0 || isInfinite x0 then 1.5 else x0
      s = showFixed d x
      neg = take 1 s == "-"
      body = if neg then drop 1 s else s
      (ip, fp) = break (== '.') body
      digits = ip ++ drop 1 fp
      shown = fromInteger (read digits) / 10 ^ d :: Rational
      err = abs (shown - toRational (abs x))
  in counterexample s (length (drop 1 fp) == d && err * 2 <= 1 / 10 ^ d)

-- | Decimal text of a double's shortest representation reads back exactly.
prop_decimalRoundTrip :: Double -> Property
prop_decimalRoundTrip x0 =
  let x = abs (if isNaN x0 || isInfinite x0 then 0.1 else x0)
      (ds, e) = floatToDigits 10 x
      m = foldl (\a dgt -> a * 10 + toInteger dgt) 0 ds
  in x > 0 ==> decimalToDouble m (toInteger e - toInteger (length ds)) === x

-- Golden files --------------------------------------------------------------------------

goldenSpec :: Spec
goldenSpec = do
  files <- runIO (sort . filter (".in" `isSuffixOf`) <$> listDirectory "test/golden")
  describe "golden programs" $
    forM_ files $ \f -> it f $ do
      let base = take (length f - 3) f
      input <- readFile ("test/golden/" ++ f)
      expected <- readFile ("test/golden/" ++ base ++ ".out")
      out <- executeText input
      normalise out `shouldBe` normalise expected

-- Diagnostics -----------------------------------------------------------------------------

type Case = (String, [String], String)

-- | Programs with a one-line @main@ body and the diagnostic they must produce.
bodyCases :: [Case]
bodyCases =
  [ ("integer too large", ["let a = 9223372036854775808;"], "error: int-range at 2:13")
  , ("hex without digits", ["let a = 0x_1;"], "error: bad-token at 2:13")
  , ("bad escape", ["let a = '\\q';"], "error: bad-escape at 2:14")
  , ("unterminated char", ["let a = 'ab';"], "error: unterminated at 2:13")
  , ("unterminated string", ["let a = \"abc;"], "error: unterminated at 2:13")
  , ("lone hash", ["let a = #5;"], "error: bad-token at 2:13")
  , ("comparison chain", ["let a = 1 < 2 < 3;"], "error: parse at 2:19")
  , ("float suffix", ["let a = 1.5e;"], "error: parse at 2:16")
  , ("mismatch on right operand", ["let n: Int = 1;", "print(n + \"x\");"], "error: type-mismatch at 3:15")
  , ("cannot infer empty list", ["var xs = [];"], "error: cannot-infer at 2:14")
  , ("cannot infer None", ["let x = None;"], "error: cannot-infer at 2:13")
  , ("assign immutable", ["let x = 1;", "x = 2;"], "error: assign-immutable at 3:5")
  , ("assign captured", ["var x = 1;", "let f = || { x = 2; };"], "error: assign-captured at 3:18")
  , ("break in lambda", ["while true { let f = || { break; }; }"], "error: break-outside at 2:31")
  , ("not callable", ["let f = 5;", "f(1);"], "error: not-callable at 3:5")
  , ("not indexable", ["let f = 5;", "print(showInt(f[0]));"], "error: not-indexable at 3:19")
  , ("not iterable", ["for c in 'a' { }"], "error: not-iterable at 2:14")
  , ("float is not Ord on lists", ["let x = [1] < [2];"], "error: not-ord at 2:13")
  , ("function is not Eq", ["let f = |x: Int| x;", "let b = f == f;"], "error: not-eq at 3:13")
  , ("float pattern", ["match 1.5 { 1.5 -> print(\"a\"), _ -> print(\"b\") }"], "error: bad-pattern at 2:17")
  , ("refutable let", ["let [a, ..] = [1];"], "error: refutable-pattern at 2:9")
  , ("unreachable arm", ["match 3 { _ -> print(\"a\"), 1 -> print(\"b\") }"], "error: unreachable at 2:32")
  , ("non-exhaustive", ["match 3 { 1 -> print(\"a\") }"], "error: non-exhaustive at 2:5")
  , ("missing field", ["let p = Nope.{ a: 1 };"], "error: unknown-type at 2:13")
  , ("bad target", ["5 = 4;"], "error: bad-target at 2:5")
  , ("unknown name", ["print(showInt(len([1])));"], "error: unknown-name at 2:19")
  , ("bad arity", ["let f = |a: Int, a: Int| a;"], "error: dup-name at 2:22")
  , ("lambda arity", ["let f: fn(Int) -> Int = |a, b| a;"], "error: type-mismatch at 2:29")
  ]

itemCases :: [(String, String, String)]
itemCases =
  [ ("reserved name", "struct Int {}", "error: reserved-name at 1:8")
  , ("duplicate function", "fn f() {}\nfn f() {}", "error: dup-name at 2:4")
  , ("duplicate variant", "enum E { A, A }", "error: dup-name at 1:13")
  , ("unknown type", "fn g(a: Foo) {}", "error: unknown-type at 1:9")
  , ("arity of type", "struct S<T> { x: T }\nfn g(s: S) {}", "error: arity-type at 2:9")
  , ("Self outside", "fn g(s: Self) {}", "error: self-outside at 1:9")
  , ("float key", "fn g(m: #[Float: Int]) {}", "error: bad-key-type at 1:9")
  , ("missing method", "trait T { fn a(self); fn b(self) -> Int; }\nimpl T for Int { fn a(self) {} }", "error: missing-method at 2:1")
  , ("extra method", "trait T { fn a(self); }\nimpl T for Int { fn a(self) {} fn z(self) {} }", "error: extra-method at 2:35")
  , ("signature mismatch", "trait T { fn a(self, x: Int) -> Int; }\nimpl T for Int { fn a(self, x: Str) -> Int { 1 } }", "error: sig-mismatch at 2:21")
  , ("duplicate impl", "trait T { fn a(self); }\nimpl T for Int { fn a(self) {} }\nimpl T for Int { fn a(self) {} }", "error: dup-impl at 3:1")
  , ("bad impl head", "trait T { fn a(self); }\nimpl T for [Int] { fn a(self) {} }", "error: bad-impl-head at 2:12")
  , ("unused parameter", "trait T { fn a(self); }\nimpl<A, B> T for [A] { fn a(self) {} }", "error: unused-param at 2:9")
  , ("builtin trait impl", "impl Eq for Int {}", "error: builtin-trait-impl at 1:1")
  ]

diagnosticsSpec :: Spec
diagnosticsSpec = describe "diagnostics" $ do
  forM_ bodyCases $ \(name, body, expected) ->
    it name $ diagnose (prog body) `shouldReturn` expected
  forM_ itemCases $ \(name, items, expected) ->
    it name $ diagnose ("@module main\n" ++ items ++ "\nfn main() {}\n") `shouldReturn` expected
  it "requires a main function" $
    diagnose "@module main\nfn helper() {}\n" `shouldReturn` "error: no-main at 1:1"
  it "reports the earliest pass first" $
    diagnose "@module main\nfn main() { let x: Int = \"s\"; }\n@module other\nfn f( {\n}\n"
      `shouldReturn` "error: parse at 1:7"
  it "reports module stream errors with whole-input line numbers" $ do
    diagnose "" `shouldReturn` "error: bad-module at 1:1"
    diagnose "@module main\nfn main() {}\n@module main\n" `shouldReturn` "error: dup-module at 3:1"
    diagnose "@module main\nfn main() {}\n@modul x\n" `shouldReturn` "error: bad-module at 3:1"
    diagnose "@module main \nfn main() {}\n" `shouldReturn` "error: bad-module at 1:1"
  it "reports an input that ends too early past the last line" $
    diagnose "@module main\nfn main() {\n    let x = 1;\n" `shouldReturn` "error: parse at 2:15"

-- Runtime behaviour ----------------------------------------------------------------------------

runtimeSpec :: Spec
runtimeSpec = describe "runtime" $ do
  let out body = executeText (prog body)
  it "wraps integer arithmetic" $
    out ["print(showInt(intMax() + 1));", "print(showInt(-7 / 2) ++ \" \" ++ showInt(-7 % 2));"]
      `shouldReturn` "-9223372036854775808\n-3 -1\n"
  it "appends the panic to unterminated output" $
    out ["emit(\"a\");", "let xs: [Int] = [];", "print(showInt(xs[0]));"]
      `shouldReturn` "apanic: index out of bounds\n"
  it "keeps the output printed before a panic" $
    out ["print(\"before\");", "panic(\"boom\");", "print(\"after\");"]
      `shouldReturn` "before\npanic: boom\n"
  it "limits the call depth to 20000 frames" $
    executeText (unlines
      [ "@module main"
      , "fn down(n: Int) -> Int { if n == 0 { 0 } else { down(n - 1) + 1 } }"
      , "fn main() { print(showInt(down(19998))); print(showInt(down(19999))); }" ])
      `shouldReturn` "19998\npanic: call stack overflow\n"
  it "runs deep recursion without using the host stack" $
    executeText (unlines
      [ "@module main"
      , "fn down(n: Int) -> Int { if n == 0 { 0 } else { 1 + down(n - 1) } }"
      , "fn main() { print(showInt(down(15000))); }" ])
      `shouldReturn` "15000\n"
  it "orders maps by insertion" $
    out [ "var m = #[\"b\": 1];", "m[\"a\"] = 2;", "mapDel(m, \"b\");", "m[\"b\"] = 3;"
        , "print(strJoin(keysOf(m), \",\"));" ]
      `shouldReturn` "a,b\n"
  it "captures closure variables by value" $
    out [ "var base = 1;", "let f = |d: Int| base + d;", "base = 100;", "print(showInt(f(5)));" ]
      `shouldReturn` "6\n"
  it "dispatches trait methods on the receiver's own type" $
    executeText (unlines
      [ "@module main"
      , "trait Show { fn show(self) -> Str; }"
      , "impl Show for Int { fn show(self) -> Str { showInt(self) } }"
      , "impl<T: Show> Show for [T] { fn show(self) -> Str { \"[\" ++ strJoin(listMap(self, |x| x.show()), \",\") ++ \"]\" } }"
      , "fn main() { print([[1, 2], [3]].show()); }" ])
      `shouldReturn` "[[1,2],[3]]\n"

apiSpec :: Spec
apiSpec = describe "library API" $ do
  let source = unlines ["@module main", "fn main() { print(showInt(6 * 7)); emit(\"x\"); }"]
  it "runSource collects the output" $ do
    ref <- newIORef ""
    r <- runSource source (\s -> modifyIORef ref (++ s))
    r `shouldBe` Right Finished
    readIORef ref `shouldReturn` "42\nx"
  it "compileText and run are separate steps" $
    case compileText source of
      Left d -> expectationFailure (renderDiagnostic d)
      Right p -> do
        ref <- newIORef ""
        o <- run p (\s -> modifyIORef ref (++ s))
        o `shouldBe` Finished
        readIORef ref `shouldReturn` "42\nx"
  it "reports a panic as an outcome" $ do
    r <- runSource (prog ["panic(\"boom\");"]) (const (return ()))
    r `shouldBe` Right (Panicked "boom")
  it "reports a compile error as a diagnostic" $
    either renderDiagnostic (const "ok") (compileText "@module a\n")
      `shouldBe` "error: no-main at 1:1"

-- Lexer and splitter -----------------------------------------------------------------------------

toks :: String -> Either Diagnostic [Tok]
toks s = map tokTok <$> lexModule (lines s)

lexerSpec :: Spec
lexerSpec = describe "lexer" $ do
  it "lexes numbers with separators and prefixes" $
    toks "0x1F 0b101 1_000 1e1_0 007" `shouldBe`
      Right [TInt 31, TInt 5, TInt 1000, TFloat 1e10, TInt 7]
  it "stops a range at the dots" $
    toks "0..3" `shouldBe` Right [TInt 0, TSym "..", TInt 3]
  it "treats 1e as an integer and an identifier" $
    toks "1e" `shouldBe` Right [TInt 1, TIdent "e"]
  it "nests block comments" $
    toks "/* a /* b */ c */ x" `shouldBe` Right [TIdent "x"]
  it "decodes escapes" $
    toks "\"a\\n\\u{41}\" '\\''" `shouldBe` Right [TStr "a\nA", TChar '\'']
  it "uses the longest operator" $
    toks "a >> b >= c ++ d" `shouldBe`
      Right [TIdent "a", TSym ">>", TIdent "b", TSym ">=", TIdent "c", TSym "++", TIdent "d"]
  it "records positions in scalar values" $
    (map tokPos <$> lexModule ["\tx", "  y"]) `shouldBe` Right [Pos 1 2, Pos 2 3]
  it "rejects non-ASCII identifiers" $
    toks "é" `shouldBe` Left (Diagnostic BadToken (Pos 1 1))

splitSpec :: Spec
splitSpec = describe "module splitting" $ do
  it "splits on headers and keeps the order" $
    fmap (map smName) (splitModules "@module a\nx\n@module b\n") `shouldBe` Right ["a", "b"]
  it "removes one CR before an LF" $
    fmap (map smLines) (splitModules "@module a\r\nx\r\n") `shouldBe` Right [["x"]]
  it "rejects keywords as module names" $
    splitModules "@module fn\n" `shouldBe` Left (Diagnostic BadModule (Pos 1 1))

numberSpec :: Spec
numberSpec = describe "number formatting" $ do
  it "formats like printf %.*f" $ do
    showFixed 6 1.0 `shouldBe` "1.000000"
    showFixed 6 (-0.0) `shouldBe` "-0.000000"
    showFixed 0 2.5 `shouldBe` "2"
    showFixed 0 3.5 `shouldBe` "4"
    showFixed 2 2.675 `shouldBe` "2.67"
    showFixed 17 (0.1 + 0.2) `shouldBe` "0.30000000000000004"
    showFixed 2 1e21 `shouldBe` "1000000000000000000000.00"
  it "rounds decimal text to the nearest double" $ do
    decimalToDouble 9007199254740993 0 `shouldBe` 9007199254740992
    decimalToDouble 1 400 `shouldSatisfy` isInfinite
    decimalToDouble 1 (-400) `shouldBe` 0

main :: IO ()
main = hspec $ do
  lexerSpec
  splitSpec
  numberSpec
  diagnosticsSpec
  runtimeSpec
  apiSpec
  goldenSpec
  describe "properties" $ do
    it "integer expressions evaluate like the model" $
      withMaxSuccess 300 prop_arith
    it "sortBy is stable" $ withMaxSuccess 100 prop_sortStable
    it "maps keep insertion order across deletes and growth" $
      withMaxSuccess 150 (forAll (resize 120 arbitrary) prop_mapModel)
    it "strJoin undoes strSplit" $ withMaxSuccess 100 prop_splitJoin
    it "showFixed is within half an ulp of the last place" $
      withMaxSuccess 500 prop_showFixedClose
    it "shortest decimal text reads back exactly" $
      withMaxSuccess 500 prop_decimalRoundTrip
  where
    _unused = nub :: [Int] -> [Int]
