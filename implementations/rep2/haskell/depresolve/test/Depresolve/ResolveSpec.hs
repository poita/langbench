{-# LANGUAGE OverloadedStrings #-}
module Depresolve.ResolveSpec (spec) where

import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy.Char8 as L
import qualified Data.String
import Test.Hspec
import Test.Hspec.QuickCheck (modifyMaxSuccess)
import Test.QuickCheck

import Depresolve
import Depresolve.Gen (genProblem)
import Depresolve.Reference (referenceResolve)

run :: String -> String
run s = case resolveText (Data.String.fromString s) of
  Left e -> error e
  Right b -> L.unpack (BB.toLazyByteString b)

spec :: Spec
spec = describe "resolve" $ do
  it "backtracks through a diamond (example 1)" $
    run "a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n"
      `shouldBe` "a 1.0.0\nb 1.0.0\nc 1.2.5\n"
  it "returns the first solution, not the newest set (example 2)" $
    run "a 2.0.0: b ~1.0.0\na 1.0.0:\nb 1.0.0:\nb 1.0.5:\nb 1.5.0:\nb 2.0.0:\nroot: a *, b *\n"
      `shouldBe` "a 2.0.0\nb 1.0.5\n"
  it "reports conflicting majors as unsatisfiable (example 3)" $
    run "a 1.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\nroot: a *, b *\n"
      `shouldBe` "unsatisfiable\n"
  it "depends on requirement order (example 4)" $ do
    let reg = "a 2.0.0: c ^2.0.0\na 1.0.0: c ^1.0.0\nb 2.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\n"
    run (reg ++ "root: a *, b *\n") `shouldBe` "a 2.0.0\nb 1.0.0\nc 2.0.0\n"
    run (reg ++ "root: b *, a *\n") `shouldBe` "a 1.0.0\nb 2.0.0\nc 1.0.0\n"
  it "prints nothing for an empty root" $ run "root:\n" `shouldBe` ""
  it "fails on a package missing from the registry" $
    run "root: nope *\n" `shouldBe` "unsatisfiable\n"
  it "allows cycles, including self-dependencies" $
    run "a 1.0.0: b *, a 1.0.0\nb 1.0.0: a *\nroot: a *\n" `shouldBe` "a 1.0.0\nb 1.0.0\n"
  it "compares versions numerically and sorts names bytewise" $
    run "mylib 1.9.0:\nmylib 1.10.0:\nmy-lib 1.0.0:\nmy-lib2 1.0.0:\nroot: mylib *, my-lib2 *, my-lib *\n"
      `shouldBe` "my-lib 1.0.0\nmy-lib2 1.0.0\nmylib 1.10.0\n"
  it "handles a very deep chain without stack problems" $ do
    let n = 20000 :: Int
        line i = "p" ++ show i ++ " 1.0.0: p" ++ show (i + 1) ++ " *\n"
        input = concatMap line [0 .. n - 1] ++ "p" ++ show n ++ " 1.0.0:\nroot: p0 *\n"
    length (lines (run input)) `shouldBe` (n + 1)
  modifyMaxSuccess (const 2000) $ it "agrees with the naive reference on random problems" $
    property $ forAll genProblem $ \p ->
      resolve p === referenceResolve p
