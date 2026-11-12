-- | Command-line front end: reads perft/divide queries from standard input
-- (one per line) and writes one result block per query to standard output.
module Main (main) where

import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, hSetBuffering, stderr, stdout, BufferMode (..))

import Chess.Perft (processInput)

usage :: String
usage = unlines
  [ "usage: chess-perft < queries"
  , ""
  , "Each input line is a FEN followed by a depth, or by 'divide' and a depth:"
  , "  <placement> <side> <castling> <ep> <halfmove> <fullmove> [divide] <depth>"
  ]

main :: IO ()
main = do
  args <- getArgs
  case args of
    [] -> pure ()
    ["-h"] -> putStr usage >> exitSuccess
    ["--help"] -> putStr usage >> exitSuccess
    _ -> hPutStrLn stderr usage >> exitFailure
  hSetBuffering stdout (BlockBuffering Nothing)
  input <- getContents
  case processInput input of
    Right out -> putStr out
    Left err -> hPutStrLn stderr ("chess-perft: " ++ err) >> exitFailure
