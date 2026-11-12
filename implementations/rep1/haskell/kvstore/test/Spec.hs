module Main (main) where

import qualified BTreeSpec
import qualified CRCSpec
import qualified ParserSpec
import qualified RecoverySpec
import qualified ScriptSpec
import qualified StoreSpec
import Test.Hspec
import qualified ValueSpec

main :: IO ()
main = hspec $ do
  CRCSpec.spec
  ValueSpec.spec
  ParserSpec.spec
  StoreSpec.spec
  BTreeSpec.spec
  ScriptSpec.spec
  RecoverySpec.spec
