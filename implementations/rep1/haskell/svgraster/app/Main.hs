-- | Command-line front end:
--
-- > svgraster <input-dir> <output-dir>
--
-- Reads @<input-dir>/render.txt@ and writes one PPM per listed SVG file.
module Main (main) where

import Control.Exception (IOException, try)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

import Graphics.SVG.Raster

main :: IO ()
main = do
  args <- getArgs
  case args of
    [inDir, outDir] -> run inDir outDir
    _ -> hPutStrLn stderr "usage: svgraster <input-dir> <output-dir>" >> exitFailure

run :: FilePath -> FilePath -> IO ()
run inDir outDir = do
  listing <- BS.readFile (inDir </> "render.txt")
  createDirectoryIfMissing True outDir
  mapM_ (renderJob inDir outDir) (parseRenderList (BC.unpack listing))

-- | Render one job. An unreadable or unusable SVG yields a white image and a
-- warning rather than aborting the whole batch.
renderJob :: FilePath -> FilePath -> RenderJob -> IO ()
renderJob inDir outDir job = do
  r <- try (BS.readFile (inDir </> jobName job)) :: IO (Either IOException BS.ByteString)
  let w = jobWidth job
      h = jobHeight job
      ppm = case r of
        Left _ -> Left "cannot read file"
        Right bytes -> renderToPPM w h (BC.unpack bytes)
  out <- case ppm of
    Right p -> pure p
    Left err -> do
      hPutStrLn stderr (jobName job ++ ": " ++ err ++ "; writing a blank image")
      pure (blankPPM w h)
  BS.writeFile (outDir </> outputName job) out
