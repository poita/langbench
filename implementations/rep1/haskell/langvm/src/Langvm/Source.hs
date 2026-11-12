-- | Splitting the input into modules (SPEC.md section 2).
module Langvm.Source
  ( SourceModule (..)
  , splitModules
  , isIdentifier
  ) where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List (stripPrefix)
import qualified Data.Set as Set

import Langvm.Diagnostic

-- | One module of the stream: its name and the lines after its header.
data SourceModule = SourceModule
  { smName :: String
  , smLines :: [String]
  } deriving (Eq, Show)

keywords :: [String]
keywords =
  [ "as", "break", "continue", "else", "enum", "false", "fn", "for", "if"
  , "impl", "in", "let", "match", "pub", "return", "self", "struct", "trait"
  , "true", "use", "var", "when", "while" ]

-- | Whether the text is a valid identifier (section 3.3) of at most 200
-- characters, and neither a keyword nor a lone @_@.
isIdentifier :: String -> Bool
isIdentifier s = case s of
  [] -> False
  (c : cs) ->
    (isAsciiLower c || isAsciiUpper c || c == '_')
      && all (\x -> isAsciiLower x || isAsciiUpper x || isDigit x || x == '_') cs
      && length s <= 200
      && s /= "_"
      && s `notElem` keywords

-- | Split on LF, dropping an empty final piece, then drop one CR before each LF.
splitLines :: String -> [String]
splitLines "" = []
splitLines s = map stripCR (go s)
  where
    go str = case break (== '\n') str of
      (l, []) -> [l]
      (l, _ : []) -> [l]
      (l, _ : rest) -> l : go rest
    stripCR l = case reverse l of
      '\r' : r -> reverse r
      _ -> l

headerName :: String -> Maybe String
headerName l = case stripPrefix "@module " l of
  Just n | isIdentifier n -> Just n
  _ -> Nothing

-- | Pass 0.  Splits the stream into modules in order, or reports
-- @bad-module@ / @dup-module@.
splitModules :: String -> Either Diagnostic [SourceModule]
splitModules input = do
  let ls = zip [1 :: Int ..] (splitLines input)
  checkHeaders ls
  let mods = build ls
  checkDups (Set.empty) [(n, nm) | (n, l) <- ls, Just nm <- [headerName l]]
  return mods
  where
    bad n = Left (Diagnostic BadModule (Pos n 1))
    checkHeaders ls = case ls of
      [] -> bad 1
      ((_, l) : _) | Nothing <- headerName l -> bad 1
      _ -> case [n | (n, l@('@' : _)) <- ls, Nothing <- [headerName l]] of
             (n : _) -> bad n
             [] -> Right ()
    checkDups _ [] = Right ()
    checkDups seen ((n, nm) : rest)
      | nm `Set.member` seen = Left (Diagnostic DupModule (Pos n 1))
      | otherwise = checkDups (Set.insert nm seen) rest
    build [] = []
    build ((_, l) : rest) = case headerName l of
      Just nm ->
        let (body, more) = break (\(_, x) -> headerName x /= Nothing) rest
        in SourceModule nm (map snd body) : build more
      Nothing -> build rest
