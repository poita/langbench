module Main (main) where

import qualified Data.ByteString.Char8 as B
import Test.Hspec
import Test.QuickCheck

import Depresolve
import Reference

run :: String -> String
run s = either error id (resolveInput (B.pack s))

main :: IO ()
main = hspec $ do
  describe "Range semantics" $ do
    let ok r x = either error (\rg -> satisfies rg x) (parseRange r)
        v = mkVersion
    it "treats * as anything" $ ok "*" (v 9 9 9) `shouldBe` True
    it "matches exact versions only" $ do
      ok "1.2.3" (v 1 2 3) `shouldBe` True
      ok "1.2.3" (v 1 2 4) `shouldBe` False
    it "caret keeps the leftmost non-zero component" $ do
      ok "^1.2.3" (v 1 9 0) `shouldBe` True
      ok "^1.2.3" (v 2 0 0) `shouldBe` False
      ok "^0.2.3" (v 0 2 9) `shouldBe` True
      ok "^0.2.3" (v 0 3 0) `shouldBe` False
      ok "^0.0.3" (v 0 0 3) `shouldBe` True
      ok "^0.0.3" (v 0 0 4) `shouldBe` False
    it "tilde keeps major and minor" $ do
      ok "~0.0.3" (v 0 0 9) `shouldBe` True
      ok "~0.0.3" (v 0 1 0) `shouldBe` False
      ok "~1.2.3" (v 1 2 2) `shouldBe` False
    it "combines comparators conjunctively" $ do
      ok ">=1.0.0 <2.0.0" (v 1 5 0) `shouldBe` True
      ok ">=1.0.0 <2.0.0" (v 2 0 0) `shouldBe` False
      ok ">1.0.0 <=1.0.5" (v 1 0 0) `shouldBe` False
      ok ">1.0.0 <=1.0.5" (v 1 0 5) `shouldBe` True
      ok ">=2.0.0 <1.0.0" (v 1 0 0) `shouldBe` False
    it "compares components numerically" $
      ok ">1.9.0" (v 1 10 0) `shouldBe` True
    it "round-trips through renderRange" $
      fmap renderRange (parseRange ">=1.0.0 <2.0.0") `shouldBe` Right ">=1.0.0 <2.0.0"

  describe "Specification examples" $ do
    it "backtracks through a diamond" $
      run "a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n"
        `shouldBe` "a 1.0.0\nb 1.0.0\nc 1.2.5\n"
    it "returns the first solution, not the newest set" $
      run "a 2.0.0: b ~1.0.0\na 1.0.0:\nb 1.0.0:\nb 1.0.5:\nb 1.5.0:\nb 2.0.0:\nroot: a *, b *\n"
        `shouldBe` "a 2.0.0\nb 1.0.5\n"
    it "reports conflicting majors" $
      run "a 1.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\nroot: a *, b *\n"
        `shouldBe` "unsatisfiable\n"
    it "depends on requirement order" $ do
      let reg = "a 2.0.0: c ^2.0.0\na 1.0.0: c ^1.0.0\nb 2.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\n"
      run (reg ++ "root: a *, b *\n") `shouldBe` "a 2.0.0\nb 1.0.0\nc 2.0.0\n"
      run (reg ++ "root: b *, a *\n") `shouldBe` "a 1.0.0\nb 2.0.0\nc 1.0.0\n"

  describe "Edge cases" $ do
    it "prints nothing for an empty root" $ run "root:\n" `shouldBe` ""
    it "fails on a missing package" $ run "root: a *\n" `shouldBe` "unsatisfiable\n"
    it "allows cycles and self-requirements" $
      run "a 1.0.0: b *, a 1.0.0\nb 1.0.0: a *\nroot: a *\n" `shouldBe` "a 1.0.0\nb 1.0.0\n"
    it "sorts output by byte order" $
      run "mylib 1.0.0:\nmy-lib2 1.0.0:\nmy-lib 1.0.0:\nroot: mylib *, my-lib2 *, my-lib *\n"
        `shouldBe` "my-lib 1.0.0\nmy-lib2 1.0.0\nmylib 1.0.0\n"
    it "prefers numerically newer versions" $
      run "a 1.9.0:\na 1.10.0:\nroot: a *\n" `shouldBe` "a 1.10.0\n"
    it "handles a deep chain" $ do
      let n = 3000 :: Int
          line i = "p" ++ show i ++ " 1.0.0: p" ++ show (i + 1) ++ " *\n"
          input = concatMap line [0 .. n - 1] ++ "p" ++ show n ++ " 1.0.0:\nroot: p0 *\n"
      length (lines (run input)) `shouldBe` n + 1

  describe "Library API" $ do
    it "resolves a programmatically built registry" $ do
      let reg = fromEntries
            [ ("a", mkVersion 1 0 0, [Requirement "b" (Caret (mkVersion 1 0 0))])
            , ("b", mkVersion 1 2 0, [])
            , ("b", mkVersion 2 0 0, []) ]
      resolve reg [Requirement "a" Any]
        `shouldBe` Just [("a", mkVersion 1 0 0), ("b", mkVersion 1 2 0)]

  describe "Against the reference search" $
    it "agrees on random registries" $
      withNumTests 2000 $ forAll genProblem $ \(reg, root) ->
        resolve reg root === referenceResolve reg root

genProblem :: Gen (Registry, [Requirement])
genProblem = do
  let names = ["a", "b", "c", "d", "e"]
  entries <- fmap concat . mapM (\n -> do
      vs <- sublistOf [mkVersion x y z | x <- [0, 1, 2], y <- [0, 1], z <- [0, 1]]
      mapM (\v -> do rs <- genReqs names; return (n, v, rs)) vs) $ take 5 names
  root <- genReqs names
  return (fromEntries entries, root)

genReqs :: [String] -> Gen [Requirement]
genReqs names = do
  ns <- sublistOf (names ++ ["zz"]) >>= shuffle
  mapM (\n -> Requirement n <$> genRange) ns

genRange :: Gen Range
genRange = oneof
  [ pure Any
  , Exact <$> genV
  , Caret <$> genV
  , Tilde <$> genV
  , Comparators <$> resize 3 (listOf1 (Comparator <$> elements [Lt, Le, Gt, Ge] <*> genV))
  ]
  where
    genV = mkVersion <$> choose (0, 2) <*> choose (0, 1) <*> choose (0, 1)
