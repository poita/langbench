-- | Golden tests: every @test/golden/*.in@ is run through the library and
-- compared with the matching @.out@ (trailing whitespace ignored).
module GoldenSpec (spec) where

import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.List (isSuffixOf, sort)
import System.Directory (listDirectory)
import System.FilePath ((</>), dropExtension)
import Test.Hspec

import Datalog (runSource)

dir :: FilePath
dir = "test/golden"

normalise :: String -> String
normalise = unlines . map (reverse . dropWhile (== ' ') . reverse) . lines

spec :: Spec
spec = do
  names <- runIO (sort . map dropExtension . filter (".in" `isSuffixOf`) <$> listDirectory dir)
  describe "golden programs" $
    mapM_ (\n -> it n (check n)) names
  where
    check n = do
      src <- B.readFile (dir </> n ++ ".in")
      expected <- readFile (dir </> n ++ ".out")
      case runSource src of
        Left e -> expectationFailure (show e)
        Right out -> normalise (BL.unpack (BB.toLazyByteString out)) `shouldBe` normalise expected
