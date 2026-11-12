module Main (main) where

import Test.Hspec

import qualified Scheme.BigIntSpec
import qualified Scheme.EvalSpec
import qualified Scheme.ReaderPrinterSpec

main :: IO ()
main = hspec $ do
  describe "Scheme.BigInt" Scheme.BigIntSpec.spec
  describe "Scheme.Reader / Scheme.Printer" Scheme.ReaderPrinterSpec.spec
  describe "Scheme (evaluation)" Scheme.EvalSpec.spec
