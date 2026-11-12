module GoldenSpec (spec) where

import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as BL
import Control.Monad (forM_)
import Data.List (isSuffixOf, sort)
import System.Directory (listDirectory)
import System.FilePath ((</>), dropExtension)
import Test.Hspec

import TextBuffer (runScript)

dir :: FilePath
dir = "test/golden"

-- | Compare ignoring trailing whitespace per line and trailing newlines.
norm :: String -> [String]
norm = reverse . dropWhile null . reverse . map (reverse . dropWhile (== ' ') . reverse) . lines

spec :: Spec
spec = do
  inputs <- runIO (sort . filter (".in" `isSuffixOf`) <$> listDirectory dir)
  forM_ inputs $ \f -> it f $ do
    input <- B.readFile (dir </> f)
    expected <- readFile (dir </> dropExtension f ++ ".out")
    case runScript input of
      Left e -> expectationFailure e
      Right out -> norm (BL.unpack (BB.toLazyByteString out)) `shouldBe` norm expected
