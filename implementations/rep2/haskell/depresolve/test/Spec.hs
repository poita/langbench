module Main (main) where

import Test.Hspec

import qualified Depresolve.ParseSpec
import qualified Depresolve.RangeSpec
import qualified Depresolve.ResolveSpec
import qualified Depresolve.VersionSpec

main :: IO ()
main = hspec $ do
  describe "Depresolve.Version" Depresolve.VersionSpec.spec
  describe "Depresolve.Range" Depresolve.RangeSpec.spec
  describe "Depresolve.Parse" Depresolve.ParseSpec.spec
  describe "Depresolve.Resolve" Depresolve.ResolveSpec.spec
