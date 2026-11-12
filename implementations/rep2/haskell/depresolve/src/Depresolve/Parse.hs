{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : Depresolve.Parse
-- Description : Parser for the textual problem format.
--
-- The format is a list of registry lines @name X.Y.Z: req, req@ followed by a
-- final @root: req, req@ line.  See the README for the grammar.
module Depresolve.Parse
  ( parseProblem
  , parseRange
  , parseVersion
  , parseRequirements
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (isDigit, isLower)

import Depresolve.Range
import Depresolve.Types
import Depresolve.Version

-- | Parse a whole input.  The last non-empty line must be the root line; every
-- earlier line is a registry line.  Returns an error message mentioning the
-- offending line number on malformed input.
parseProblem :: ByteString -> Either String Problem
parseProblem input =
  case reverse ls of
    [] -> Left "empty input: missing root line"
    (rootLine : revRegistry) -> do
      root <- withLine (length ls) (parseRootLine rootLine)
      registry <- mapM (\(n, l) -> withLine n (parseRegistryLine l)) (zip [1 ..] (reverse revRegistry))
      Right (Problem registry root)
  where
    ls = B.lines input
    withLine n = either (\e -> Left ("line " ++ show (n :: Int) ++ ": " ++ e)) Right

parseRootLine :: ByteString -> Either String [Requirement]
parseRootLine l = case B.stripPrefix "root:" l of
  Nothing -> Left "expected a root line starting with \"root:\""
  Just rest -> parseRequirements rest

parseRegistryLine :: ByteString -> Either String PackageVersion
parseRegistryLine l = do
  let (head', rest) = B.break (== ':') l
  (name, verText) <- case B.split ' ' head' of
    [n, v] | validName n -> Right (n, v)
    _ -> Left "expected \"name version:\""
  version <- parseVersion verText
  reqs <- parseRequirements (B.drop 1 rest)
  if B.null rest then Left "missing ':'" else Right (PackageVersion name version reqs)

-- | Parse what follows the colon: empty, or a space and comma-separated
-- requirements.
parseRequirements :: ByteString -> Either String [Requirement]
parseRequirements t
  | B.null t = Right []
  | otherwise = case B.uncons t of
      Just (' ', body) -> mapM parseRequirement (splitOn ", " body)
      _ -> Left "expected a space after ':'"

parseRequirement :: ByteString -> Either String Requirement
parseRequirement t =
  case B.break (== ' ') t of
    (n, r)
      | validName n, not (B.null r) -> Requirement n <$> parseRange (B.drop 1 r)
    _ -> Left ("bad requirement: " ++ show t)

-- | Parse a range: @*@, @X.Y.Z@, @^X.Y.Z@, @~X.Y.Z@ or space-separated
-- comparators.
parseRange :: ByteString -> Either String Range
parseRange t = case B.uncons t of
  Just ('*', r) | B.null r -> Right Any
  Just ('^', r) -> Caret <$> parseVersion r
  Just ('~', r) -> Tilde <$> parseVersion r
  Just (c, _)
    | isDigit c -> Exact <$> parseVersion t
    | c == '<' || c == '>' -> Comparators <$> mapM parseComparator (B.split ' ' t)
  _ -> Left ("bad range: " ++ show t)

parseComparator :: ByteString -> Either String Comparator
parseComparator t
  | Just r <- B.stripPrefix "<=" t = Comparator Le <$> parseVersion r
  | Just r <- B.stripPrefix ">=" t = Comparator Ge <$> parseVersion r
  | Just r <- B.stripPrefix "<" t = Comparator Lt <$> parseVersion r
  | Just r <- B.stripPrefix ">" t = Comparator Gt <$> parseVersion r
  | otherwise = Left ("bad comparator: " ++ show t)

-- | Parse @MAJOR.MINOR.PATCH@.
parseVersion :: ByteString -> Either String Version
parseVersion t = case mapM num (B.split '.' t) of
  Just [a, b, c] -> Right (Version a b c)
  _ -> Left ("bad version: " ++ show t)
  where
    num s = case B.readInt s of
      Just (n, r) | B.null r, B.all isDigit s, B.length s == 1 || B.head s /= '0' -> Just n
      _ -> Nothing

validName :: ByteString -> Bool
validName n = case B.uncons n of
  Just (c, r) -> isLower c && B.all (\x -> isLower x || isDigit x || x == '-') r
  Nothing -> False

-- | Split on a (non-empty) separator string.
splitOn :: ByteString -> ByteString -> [ByteString]
splitOn sep s = case B.breakSubstring sep s of
  (a, b) | B.null b -> [a]
         | otherwise -> a : splitOn sep (B.drop (B.length sep) b)
