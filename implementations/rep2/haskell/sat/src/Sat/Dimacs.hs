{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : Sat.Dimacs
-- Description : Reading DIMACS CNF and writing solver results.
module Sat.Dimacs
  ( parseDimacs
  , renderResult
  ) where

import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Char8 as BS
import Data.List (intersperse)

import Sat.Types

-- | Parse a DIMACS CNF document.
--
-- Comment lines (first non-blank character @c@) and blank lines are ignored
-- anywhere.  Clauses are runs of integers terminated by @0@ and may span
-- lines or share a line.  Returns a message on a malformed document: missing
-- or repeated header, literal out of range, unterminated last clause, or a
-- clause count that differs from the header's.
parseDimacs :: BS.ByteString -> Either String CNF
parseDimacs input = go (BS.lines input) Nothing [] [] (0 :: Int)
  where
    go [] hdr cur acc n = finish hdr cur acc n
    go (raw : rest) hdr cur acc n =
      let line = BS.dropWhile isBlank raw
      in case BS.uncons line of
           Nothing -> go rest hdr cur acc n
           Just ('c', _) -> go rest hdr cur acc n
           Just ('p', _) -> case hdr of
             Just _ -> Left "duplicate problem line"
             Nothing -> do
               h <- parseHeader line
               go rest (Just h) cur acc n
           Just _ -> case hdr of
             Nothing -> Left "clause data before the problem line"
             Just h@(nv, _) -> do
               (cur', acc', n') <- clauseTokens nv (BS.words line) cur acc n
               go rest (Just h) cur' acc' n'

    clauseTokens _ [] cur acc n = Right (cur, acc, n)
    clauseTokens nv (t : ts) cur acc n =
      case BS.readInt t of
        Just (k, r) | BS.null r ->
          if k == 0
            then clauseTokens nv ts [] (reverse cur : acc) (n + 1)
            else if abs k > nv
              then Left ("literal out of range: " ++ show k)
              else clauseTokens nv ts (k : cur) acc n
        _ -> Left ("bad token in clause data: " ++ show t)

    finish Nothing _ _ _ = Left "missing problem line"
    finish (Just (nv, nc)) cur acc n
      | not (null cur) = Left "last clause is not terminated by 0"
      | n /= nc = Left ("expected " ++ show nc ++ " clauses, found " ++ show n)
      | otherwise = Right (CNF nv (reverse acc))

    isBlank ch = ch == ' ' || ch == '\t'

    parseHeader line = case BS.words line of
      ["p", "cnf", v, c]
        | Just (nv, r1) <- BS.readInt v, BS.null r1, nv >= 0
        , Just (nc, r2) <- BS.readInt c, BS.null r2, nc >= 0 -> Right (nv, nc)
      _ -> Left "malformed problem line"

-- | Render a result in the competition-style output of the command-line tool:
-- @UNSAT@, or @SAT@ followed by a line with one literal per variable and a
-- terminating @0@.
renderResult :: Result -> B.Builder
renderResult Unsatisfiable = "UNSAT\n"
renderResult (Satisfiable m) =
  "SAT\n" <> mconcat (intersperse " " (map B.intDec (modelLiterals m ++ [0]))) <> "\n"
