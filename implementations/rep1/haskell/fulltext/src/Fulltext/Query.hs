{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : Fulltext.Query
-- Description : The query language: lexer, recursive-descent parser, atoms.
--
-- Parsing never fails: every input yields a query tree or the empty tree
-- ('Nothing').  Juxtaposition means @AND@; @NOT@ binds tightest, then @AND@,
-- then @OR@.  A phrase (or a bare word) is analysed like document text and
-- becomes an 'Atom'.
module Fulltext.Query
  ( Atom (..)
  , atomLength
  , Query (..)
  , parseQuery
  , positiveAtoms
  , allAtoms
  , makeAtom
  ) where

import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T

import Fulltext.Analysis

-- | A phrase atom: the sequence of its (analysed) terms.  Two atoms are the
-- same atom when their term lists are equal.
newtype Atom = Atom { atomTerms :: [Text] } deriving (Eq, Ord, Show)

-- | Number of terms of an atom.
atomLength :: Atom -> Int
atomLength = length . atomTerms

-- | A parsed query.
data Query
  = QAtom Atom
  | QNot Query
  | QAnd [Query]
  | QOr [Query]
  deriving (Eq, Show)

data Tok = TOpen | TClose | TAnd | TOr | TNot | TAtom (Maybe Atom)
  deriving (Eq, Show)

-- | Analyse a phrase body into an atom.  Zero terms, or a single stop word,
-- give 'Nothing' (the empty atom).
makeAtom :: Text -> Maybe Atom
makeAtom body = case map tokText (tokenize body) of
  [] -> Nothing
  [t] | isStopWord t -> Nothing
  ts -> Just (Atom (map termOf ts))

lexQuery :: String -> [Tok]
lexQuery [] = []
lexQuery (c : cs)
  | isSpaceChar c = lexQuery cs
  | c == '(' = TOpen : lexQuery cs
  | c == ')' = TClose : lexQuery cs
  | c == '"' = let (body, rest) = break (== '"') cs
               in TAtom (makeAtom (T.pack body)) : lexQuery (drop 1 rest)
  | otherwise =
      let (w, rest) = break (\x -> isSpaceChar x || x `elem` ("()\"" :: String)) (c : cs)
          tok = case w of
                  "AND" -> TAnd
                  "OR" -> TOr
                  "NOT" -> TNot
                  _ -> TAtom (makeAtom (T.pack w))
      in tok : lexQuery rest

-- | Parse a query line.  'Nothing' is the empty tree, which matches no
-- document.
parseQuery :: Text -> Maybe Query
parseQuery = fst . parseOr . lexQuery . T.unpack

type P = ([Tok] -> (Maybe Query, [Tok]))

combine :: ([Query] -> Query) -> [Maybe Query] -> Maybe Query
combine mk rs = case [q | Just q <- rs] of
  [] -> Nothing
  [q] -> Just q
  qs -> Just (mk qs)

parseOr :: P
parseOr ts0 = loop [r0] rest0
  where
    (r0, rest0) = parseAnd ts0
    loop acc (TOr : ts) = let (r, ts') = parseAnd ts in loop (r : acc) ts'
    loop acc ts = (combine QOr (reverse acc), ts)

parseAnd :: P
parseAnd = loop []
  where
    loop acc ts = case ts of
      [] -> done acc ts
      (TClose : _) -> done acc ts
      (TOr : _) -> done acc ts
      (TAnd : ts') -> loop acc ts'
      _ -> let (r, ts') = parseNot ts in loop (r : acc) ts'
    done acc ts = (combine QAnd (reverse acc), ts)

parseNot :: P
parseNot = count (0 :: Int)
  where
    count n (TNot : ts) = count (n + 1) ts
    count n ts =
      let (r, ts') = parsePrimary ts
      in (fmap (\q -> iterate QNot q !! n) r, ts')

parsePrimary :: P
parsePrimary ts = case ts of
  (TOpen : ts') ->
    let (r, rest) = parseOr ts'
    in (r, case rest of
             (TClose : rest') -> rest'
             _ -> rest)
  (TClose : _) -> (Nothing, ts)
  (TAtom a : ts') -> (QAtom <$> a, ts')
  (_ : ts') -> (Nothing, ts')
  [] -> (Nothing, [])

-- | The positive atoms (an even number of enclosing @NOT@s), in order of
-- first appearance, without duplicates.
positiveAtoms :: Query -> [Atom]
positiveAtoms = nub . go True
  where
    go pos q = case q of
      QAtom a -> [a | pos]
      QNot x -> go (not pos) x
      QAnd xs -> concatMap (go pos) xs
      QOr xs -> concatMap (go pos) xs

-- | Every atom of the query, positive or not, without duplicates.
allAtoms :: Query -> [Atom]
allAtoms = nub . go
  where
    go q = case q of
      QAtom a -> [a]
      QNot x -> go x
      QAnd xs -> concatMap go xs
      QOr xs -> concatMap go xs
