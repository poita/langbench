module Main (main) where

import Test.Hspec

import qualified CanvasSpec
import qualified ParseSpec
import qualified PathSpec
import qualified RenderSpec
import qualified StrokeSpec
import qualified XmlSpec

main :: IO ()
main = hspec $ do
  describe "Xml" XmlSpec.spec
  describe "Parse" ParseSpec.spec
  describe "Path" PathSpec.spec
  describe "Stroke" StrokeSpec.spec
  describe "Canvas" CanvasSpec.spec
  describe "Render" RenderSpec.spec
