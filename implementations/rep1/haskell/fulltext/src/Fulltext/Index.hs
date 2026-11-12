{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : Fulltext.Index
-- Description : The positional inverted index.
--
-- The index is built once over all documents.  Postings are stored in a
-- single flat array: every occurrence of a term is a /key/
-- @docIndex * 2^32 + position@, the keys of one term are contiguous and
-- sorted, and a term's slice is found through an offset table.  Because keys
-- sort by document and then by position, phrase matching is a merge of
-- sorted lists (see "Fulltext.Search").
module Fulltext.Index
  ( -- * Building
    Index
  , buildIndex
    -- * Documents
  , Document (..)
  , DocIx
  , tokenSpan
  , documents
  , document
    -- * Corpus statistics
  , numDocs
  , totalTokens
  , numTerms
  , avgDocLength
    -- * Postings
  , TermId
  , lookupTerm
  , termKeys
  , termPostings
  , mkKey
  , keyDoc
  , keyPos
  , groupKeys
  ) where

import Control.Monad (forM_)
import Data.Array (Array, listArray, (!))
import qualified Data.Array as A
import Control.Monad.ST (ST)
import Data.Array.ST (STUArray, runSTUArray, newArray, readArray, writeArray, thaw)
import Data.Array.Unboxed (UArray, accumArray, bounds)
import qualified Data.Array.Unboxed as U
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)

import Fulltext.Analysis (Token (..), termOf, tokenize)

-- | Position of a document in the id-sorted document list.
type DocIx = Int

-- | Dense identifier of an index term.
type TermId = Int

-- | A document of the corpus.
data Document = Document
  { docId     :: !Text  -- ^ the document id
  , docText   :: !Text  -- ^ the original text
  , docLength :: !Int   -- ^ number of tokens, stop words included
  , docSpans  :: (UArray Int Int, UArray Int Int)
    -- ^ start and end code-point offsets of each token (computed lazily)
  }

-- | Character span @[start, end)@ of the token at the given position.
tokenSpan :: Document -> Int -> (Int, Int)
tokenSpan d p = let (s, e) = docSpans d in (s U.! p, e U.! p)

-- | An immutable positional index over a corpus.
data Index = Index
  { ixDocs    :: !(Array DocIx Document)
  , ixTerms   :: !(Map Text TermId)
  , ixOffsets :: !(UArray TermId Int)  -- ^ start of each term's slice; one extra entry at the end
  , ixKeys    :: !(UArray Int Int)
  , ixTotal   :: !Int
  }

-- | Pack a document index and a position into one sortable key.
mkKey :: DocIx -> Int -> Int
mkKey d p = (d `shiftL` 32) .|. p

-- | The document part of a key.
keyDoc :: Int -> DocIx
keyDoc k = k `shiftR` 32

-- | The position part of a key.
keyPos :: Int -> Int
keyPos k = k .&. 0xFFFFFFFF

data BState = BState
  { bsTerms :: !(Map Text TermId)  -- term -> id
  , bsCache :: !(Map Text TermId)  -- folded token text -> id (stemming memo)
  , bsNext  :: !TermId
  }

termIdFor :: BState -> Text -> (TermId, BState)
termIdFor st@(BState terms cache n) tok = case Map.lookup tok cache of
  Just i -> (i, st)
  Nothing ->
    let term = termOf tok
    in case Map.lookup term terms of
         Just i -> (i, st { bsCache = Map.insert tok i cache })
         Nothing -> (n, BState (Map.insert term n terms) (Map.insert tok n cache) (n + 1))

-- | Analyse one document into the array of its term ids.
indexDocument :: BState -> Text -> (UArray Int Int, BState)
indexDocument st0 text = go st0 [] (0 :: Int) (tokenize text)
  where
    go st acc !n [] = (U.listArray (0, n - 1) (reverse acc), st)
    go st acc !n (t : ts) =
      let (i, st') = termIdFor st (tokText t)
      in i `seq` go st' (i : acc) (n + 1) ts

-- | Build an index from @(document id, text)@ pairs.  Documents are ordered
-- by id (code point order); ids are assumed to be unique.
buildIndex :: [(Text, Text)] -> Index
buildIndex raw = Index
  { ixDocs = docArr
  , ixTerms = bsTerms final
  , ixOffsets = offsets
  , ixKeys = keys
  , ixTotal = total
  }
  where
    sorted = sortOn fst raw
    n = length sorted
    step (st, acc) (_, text) =
      let (arr, st') = indexDocument st text in arr `seq` (st', arr : acc)
    (final, revArrs) = foldl' step (BState Map.empty Map.empty 0, []) sorted
    termArrs = reverse revArrs
    nTerms = bsNext final
    lens = [ rangeSize' (bounds a) | a <- termArrs ]
    rangeSize' (lo, hi) = hi - lo + 1
    total = sum lens
    docArr = listArray (0, n - 1)
      [ Document i t l (spansOf t) | ((i, t), l) <- zip sorted lens ]
    spansOf t =
      let toks = tokenize t
          l = length toks
      in ( U.listArray (0, l - 1) (map tokStart toks)
         , U.listArray (0, l - 1) (map tokEnd toks) )
    counts :: UArray TermId Int
    counts = accumArray (+) 0 (0, nTerms - 1) [ (t, 1) | a <- termArrs, t <- U.elems a ]
    offsets :: UArray TermId Int
    offsets = U.listArray (0, nTerms) (scanl (+) 0 (U.elems counts))
    keys :: UArray Int Int
    keys = runSTUArray $ do
      out <- newArray (0, total - 1) 0
      cursor <- thawU offsets
      forM_ (zip [0 ..] termArrs) $ \(d, a) ->
        forM_ (U.assocs a) $ \(p, t) -> do
          c <- readArray cursor t
          writeArray out c (mkKey d p)
          writeArray cursor t (c + 1)
      pure out

thawU :: UArray Int Int -> ST s (STUArray s Int Int)
thawU = thaw

-- | All documents, in id order.
documents :: Index -> [Document]
documents = A.elems . ixDocs

-- | The document at a given index.
document :: Index -> DocIx -> Document
document ix d = ixDocs ix ! d

-- | Number of documents, @N@.
numDocs :: Index -> Int
numDocs ix = let (lo, hi) = A.bounds (ixDocs ix) in hi - lo + 1

-- | Total number of tokens over all documents.
totalTokens :: Index -> Int
totalTokens = ixTotal

-- | Number of distinct terms (stop words included).
numTerms :: Index -> Int
numTerms = Map.size . ixTerms

-- | Mean document length; 0 for an empty corpus.
avgDocLength :: Index -> Double
avgDocLength ix
  | n == 0 = 0
  | otherwise = fromIntegral (ixTotal ix) / fromIntegral n
  where n = numDocs ix

-- | The id of an (already analysed) term, if it occurs in the corpus.
lookupTerm :: Index -> Text -> Maybe TermId
lookupTerm ix t = Map.lookup t (ixTerms ix)

-- | The sorted occurrence keys of a term (see 'mkKey').
termKeys :: Index -> TermId -> [Int]
termKeys ix t = [ ixKeys ix U.! i | i <- [ixOffsets ix U.! t .. ixOffsets ix U.! (t + 1) - 1] ]

-- | The postings of an analysed term: for each containing document (in
-- index order) the sorted token positions.
termPostings :: Index -> Text -> [(DocIx, [Int])]
termPostings ix t = case lookupTerm ix t of
  Nothing -> []
  Just i -> groupKeys (termKeys ix i)

-- | Group sorted keys by document.
groupKeys :: [Int] -> [(DocIx, [Int])]
groupKeys [] = []
groupKeys (k : ks) = (d, keyPos k : map keyPos same) : groupKeys rest
  where
    d = keyDoc k
    (same, rest) = span ((== d) . keyDoc) ks
