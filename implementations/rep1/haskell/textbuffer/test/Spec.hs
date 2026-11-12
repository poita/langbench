module Main (main) where

import Test.Hspec

import qualified BufferSpec
import qualified CommandSpec
import qualified CursorSpec
import qualified DocumentSpec
import qualified GoldenSpec
import qualified PropertySpec

main :: IO ()
main = hspec $ do
  describe "Document" DocumentSpec.spec
  describe "Command" CommandSpec.spec
  describe "Cursor" CursorSpec.spec
  describe "Buffer" BufferSpec.spec
  describe "Golden scripts" GoldenSpec.spec
  describe "Properties" PropertySpec.spec
