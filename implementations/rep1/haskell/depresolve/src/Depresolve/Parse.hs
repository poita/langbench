-- | Parser for the line-oriented registry-plus-root input format.
module Depresolve.Parse
  ( parseProblem
  , parseRange
  , parseVersion
  , parseRequirements
  ) where

import qualified Data.ByteString.Char8 as B
import Data.Char (isDigit, isLower)

import Depresolve.Range
import Depresolve.Registry
import Depresolve.Version

-- | Parse a whole input: registry lines followed by the final @root:@ line.
-- Returns the registry and the root requirements.
parseProblem :: B.ByteString -> Either String (Registry, [Requirement])
parseProblem input = go emptyRegistry (B.lines input)
  where
    go _ [] = Left "missing root line"
    go reg [l]
      | Just rest <- B.stripPrefix (B.pack "root:") l = do
          rs <- parseRequirements (B.unpack rest)
          Right (reg, rs)
    go reg (l : ls) = do
      (n, v, rs) <- parseRegistryLine (B.unpack l)
      let reg' = addVersion n v rs reg
      reg' `seq` go reg' ls

parseRegistryLine :: String -> Either String (PackageName, Version, [Requirement])
parseRegistryLine s = do
  let (n, r1) = span (/= ' ') s
  if null n then Left ("bad registry line: " ++ s) else Right ()
  r2 <- case r1 of
    ' ' : r -> Right r
    _ -> Left ("bad registry line: " ++ s)
  let (vs, r3) = break (== ':') r2
  v <- parseVersion vs
  rest <- case r3 of
    ':' : r -> Right r
    _ -> Left ("missing colon: " ++ s)
  rs <- parseRequirements rest
  Right (n, v, rs)

-- | Parse the text after the colon: empty, or @" req, req, ..."@.
parseRequirements :: String -> Either String [Requirement]
parseRequirements "" = Right []
parseRequirements (' ' : s) = mapM parseReq (splitOn ", " s)
parseRequirements s = Left ("bad requirements: " ++ s)

parseReq :: String -> Either String Requirement
parseReq s = case break (== ' ') s of
  (n, ' ' : r)
    | validName n -> Requirement n <$> parseRange r
  _ -> Left ("bad requirement: " ++ s)

validName :: String -> Bool
validName (c : cs) = isLower c && all (\x -> isLower x || isDigit x || x == '-') cs
validName [] = False

-- | Parse a range such as @*@, @1.2.3@, @^1.2.3@, @~1.2.3@ or @>=1.0.0 <2.0.0@.
parseRange :: String -> Either String Range
parseRange "*" = Right Any
parseRange ('^' : s) = Caret <$> parseVersion s
parseRange ('~' : s) = Tilde <$> parseVersion s
parseRange s@(c : _)
  | isDigit c = Exact <$> parseVersion s
  | otherwise = Comparators <$> mapM parseComparator (words s)
parseRange s = Left ("bad range: " ++ s)

parseComparator :: String -> Either String Comparator
parseComparator s = case s of
  '<' : '=' : r -> Comparator Le <$> parseVersion r
  '>' : '=' : r -> Comparator Ge <$> parseVersion r
  '<' : r -> Comparator Lt <$> parseVersion r
  '>' : r -> Comparator Gt <$> parseVersion r
  _ -> Left ("bad comparator: " ++ s)

-- | Parse @MAJOR.MINOR.PATCH@.
parseVersion :: String -> Either String Version
parseVersion s = case splitOn "." s of
  [a, b, c] | all num [a, b, c] -> Right (Version (read a) (read b) (read c))
  _ -> Left ("bad version: " ++ s)
  where
    num x = not (null x) && all isDigit x

splitOn :: String -> String -> [String]
splitOn sep = go ""
  where
    n = length sep
    go acc [] = [reverse acc]
    go acc r@(c : cs)
      | take n r == sep = reverse acc : go "" (drop n r)
      | otherwise = go (c : acc) cs
