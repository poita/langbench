-- |
-- Module      : Chess.Perft.Query
-- Description : The line-oriented query format used by the command-line tool.
--
-- A query line is a six-field FEN followed by either a depth (perft) or the
-- word @divide@ and a depth.
module Chess.Perft.Query
  ( Query (..)
  , parseQuery
  , runQuery
  , processInput
  ) where

import Data.Char (isDigit)

import Chess.Perft.Position
import Chess.Perft.Search
import Chess.Perft.Types (moveToUci)

-- | A parsed query.
data Query
  = PerftQuery !Int Position
  | DivideQuery !Int Position
  deriving (Eq, Show)

-- | Parse one query line (without its newline).
parseQuery :: String -> Either String Query
parseQuery line = case words line of
  ws@[_, _, _, _, _, _] -> Left ("missing depth: " ++ unwords ws)
  [a, b, c, d, e, f, n] -> PerftQuery <$> depth n <*> fen [a, b, c, d, e, f]
  [a, b, c, d, e, f, "divide", n] -> DivideQuery <$> depth n <*> fen [a, b, c, d, e, f]
  _ -> Left ("malformed query: " ++ line)
  where
    fen = parseFen . unwords
    depth d
      | not (null d) && all isDigit d = Right (read d)
      | otherwise = Left ("bad depth: " ++ d)

-- | The output lines for a query: one count for perft; for divide, one
-- @move count@ line per legal move and a final @total n@ line.
runQuery :: Query -> [String]
runQuery (PerftQuery d pos) = [show (perft d pos)]
runQuery (DivideQuery d pos) =
  [moveToUci m ++ " " ++ show n | (m, n) <- results]
    ++ ["total " ++ show (sum (map snd results))]
  where
    results = divide d pos

-- | Answer every query in the input text, producing the output text. Blank
-- lines are skipped; the first malformed line yields a 'Left'.
processInput :: String -> Either String String
processInput input = unlines . concat <$> traverse (fmap runQuery . parseQuery) ls
  where
    ls = filter (not . null) (lines input)
