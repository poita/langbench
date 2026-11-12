-- |
-- Module      : Sat.Dimacs
-- Description : Reading DIMACS CNF and writing solver answers.
module Sat.Dimacs
  ( parseDimacs
  , renderCNF
  , renderResult
  ) where

import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Char8 as BS
import Data.ByteString.Char8 (ByteString)
import Data.Char (isSpace)
import Data.List (intersperse)

import Sat.Types

-- | Parse a DIMACS CNF document.
--
-- Blank lines and comment lines (first non-blank character @c@) are ignored
-- anywhere. The single @p cnf V C@ header must precede the clause data. The
-- remaining integers form one stream in which each @0@ terminates a clause,
-- so clauses may span lines and lines may hold several clauses. The clause
-- count in the header is not enforced; the clauses actually present are
-- returned.
parseDimacs :: ByteString -> Either String CNF
parseDimacs input = go Nothing [] [] (BS.lines input)
  where
    -- state: header (variable count), reversed finished clauses, reversed
    -- literals of the clause in progress
    go Nothing _ _ [] = Left "missing 'p cnf' header"
    go (Just v) done cur []
      | null cur  = Right (CNF v (reverse done))
      | otherwise = Left "last clause is not terminated by 0"
    go hdr done cur (l : ls) =
      case BS.uncons (BS.dropWhile isBlank l) of
        Nothing -> go hdr done cur ls
        Just ('c', _) -> go hdr done cur ls
        Just ('p', _) -> case (hdr, BS.words l) of
          (Nothing, [p, cnf, v, _]) | p == BS.pack "p", cnf == BS.pack "cnf"
                                    , Just (nv, r) <- BS.readInt v, BS.null r
                                    -> go (Just nv) done cur ls
          _ -> Left ("bad header line: " ++ BS.unpack l)
        Just _ -> case hdr of
          Nothing -> Left "clause data before header"
          Just _ -> do
            (done', cur') <- ints done cur (BS.words l)
            go hdr done' cur' ls
    ints done cur [] = Right (done, cur)
    ints done cur (w : ws) = case BS.readInt w of
      Just (0, r) | BS.null r -> ints (reverse cur : done) [] ws
      Just (n, r) | BS.null r -> ints done (n : cur) ws
      _ -> Left ("bad token: " ++ BS.unpack w)
    isBlank c = c == ' ' || c == '\t' || isSpace c

-- | Render a formula as DIMACS CNF.
renderCNF :: CNF -> B.Builder
renderCNF (CNF n cs) =
  B.string7 "p cnf " <> B.intDec n <> B.char7 ' ' <> B.intDec (length cs) <> B.char7 '\n'
    <> mconcat [ spaced (map B.intDec c ++ [B.char7 '0']) <> B.char7 '\n' | c <- cs ]

-- | Render a result in the output format of the command-line tool:
-- @UNSAT@, or @SAT@ followed by a line of @V@ literals and a final @0@.
renderResult :: Result -> B.Builder
renderResult Unsat = B.string7 "UNSAT\n"
renderResult (Sat m) =
  B.string7 "SAT\n" <> spaced (map B.intDec (modelLiterals m) ++ [B.char7 '0']) <> B.char7 '\n'

spaced :: [B.Builder] -> B.Builder
spaced = mconcat . intersperse (B.char7 ' ')
