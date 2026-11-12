-- | Runs every match file in @test/golden@ and compares the log with the
-- expected output (trailing whitespace ignored).
module GoldenSpec (spec) where

import Control.Monad (forM_)
import Data.List (isSuffixOf, sort)
import System.Directory (listDirectory)
import Test.Hspec

import Spiremark (runMatchText)

-- The golden inputs name their database as @data/...@; the fixtures live in
-- @test/data@.
retarget :: String -> String
retarget = unlines . map fix . lines
  where
    fix l = case words l of
      ["CARDS", p] | take 5 p == "data/" -> "CARDS test/" ++ p
      _ -> l

normalise :: String -> [String]
normalise = reverse . dropWhile null . reverse . map (reverse . dropWhile (== ' ') . reverse) . lines

spec :: Spec
spec = do
  names <- runIO (sort . filter (".in" `isSuffixOf`) <$> listDirectory "test/golden")
  forM_ names $ \n -> do
    let base = take (length n - 3) n
    it base $ do
      input <- readFile ("test/golden/" ++ n)
      expected <- readFile ("test/golden/" ++ base ++ ".out")
      out <- runMatchText (retarget input)
      normalise (unlines out) `shouldBe` normalise expected
