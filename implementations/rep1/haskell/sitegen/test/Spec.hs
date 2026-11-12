module Main (main) where

import Test.Hspec

import qualified Sitegen.ContentSpec
import qualified Sitegen.FeedSpec
import qualified Sitegen.GenerateSpec
import qualified Sitegen.MarkdownSpec
import qualified Sitegen.SiteSpec
import qualified Sitegen.TemplateSpec
import qualified Sitegen.TomlSpec

main :: IO ()
main = hspec $ do
  describe "Sitegen.Toml" Sitegen.TomlSpec.spec
  describe "Sitegen.Markdown" Sitegen.MarkdownSpec.spec
  describe "Sitegen.Template" Sitegen.TemplateSpec.spec
  describe "Sitegen.Content" Sitegen.ContentSpec.spec
  describe "Sitegen.Site" Sitegen.SiteSpec.spec
  describe "Sitegen.Feed" Sitegen.FeedSpec.spec
  describe "Sitegen.Generate" Sitegen.GenerateSpec.spec
