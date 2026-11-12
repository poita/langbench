-- | Command-line front end: reads scrambles (one per line) on stdin and
-- writes one solution per line on stdout.
module Main (main) where

import Data.ByteString.Builder (Builder, char7, hPutBuilder, string7)
import Data.ByteString.Char8 qualified as B
import System.Exit (exitFailure)
import System.IO (BufferMode (..), hPutStrLn, hSetBinaryMode, hSetBuffering, stderr, stdin, stdout)

import Rubiks

main :: IO ()
main = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  hSetBuffering stdout (BlockBuffering Nothing)
  input <- B.getContents
  case mapM parseLine (zip [1 :: Int ..] (scrambleLines input)) of
    Left err -> hPutStrLn stderr err >> exitFailure
    Right scrambles ->
      hPutBuilder stdout (foldMap (solutionLine . solveScramble newSolver) scrambles)

-- | Split input into scramble lines: a final newline terminates the last line
-- rather than starting a new empty one.
scrambleLines :: B.ByteString -> [B.ByteString]
scrambleLines s
  | B.null body = [B.empty]
  | otherwise = B.split '\n' body
  where
    body = if B.isSuffixOf (B.pack "\n") s then B.init s else s

parseLine :: (Int, B.ByteString) -> Either String [Move]
parseLine (n, line) = either (\e -> Left ("line " ++ show n ++ ": " ++ e)) Right (parseMoves (B.unpack line))

solutionLine :: [Move] -> Builder
solutionLine ms = string7 (renderMoves ms) <> char7 '\n'
