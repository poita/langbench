module Main (main) where

import qualified CalendarSpec
import qualified ExpandSpec
import qualified ParseSpec
import Test.Hspec

main :: IO ()
main = hspec $ do
  describe "RRule.Calendar" CalendarSpec.spec
  describe "RRule.Parse" ParseSpec.spec
  describe "RRule.Expand" ExpandSpec.spec
