-- | End-to-end tests: every directory under @test/golden@ holds an @input@
-- directory and the @expected@ output files.
module Typeset.GoldenSpec (spec) where

import Control.Monad (forM_)
import Data.List (dropWhileEnd, sort)
import System.Directory
import System.FilePath ((</>))
import Test.Hspec

import Typeset
import Typeset.Font (ioReadUtf8)

normalise :: String -> String
normalise = dropWhileEnd (== '\n') . unlines' . map (dropWhileEnd (`elem` " \t")) . lines
  where unlines' = foldr (\l r -> l ++ "\n" ++ r) ""

readMaybe' :: FilePath -> IO (Maybe String)
readMaybe' p = do
  e <- doesFileExist p
  if e then Just <$> ioReadUtf8 p else return Nothing

spec :: Spec
spec = do
  res <- runIO (loadResources "data")
  cases <- runIO (sort <$> listDirectory "test/golden")
  forM_ cases $ \name -> it name $ do
    let dir = "test/golden" </> name
    doc <- readMaybe' (dir </> "input" </> "document.cdx")
    cfg <- readMaybe' (dir </> "input" </> "settings.cfg")
    expectedErr <- readMaybe' (dir </> "expected" </> "error.txt")
    case (typeset res cfg doc, expectedErr) of
      (Left e, Just want) -> normalise (renderError e ++ "\n") `shouldBe` normalise want
      (Left e, Nothing) -> expectationFailure ("unexpected error: " ++ renderError e)
      (Right _, Just want) -> expectationFailure ("expected error: " ++ want)
      (Right o, Nothing) -> do
        Just layout <- readMaybe' (dir </> "expected" </> "layout.txt")
        Just report <- readMaybe' (dir </> "expected" </> "report.txt")
        normalise (outLayout o) `shouldBe` normalise layout
        normalise (outReport o) `shouldBe` normalise report
