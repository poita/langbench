-- | A small hash table keyed by lists of values, used for hash joins and
-- grouping. Keys are equal when 'compareValues' says so on every component.
module MiniSQL.Hash
  ( HashTable
  , fromPairs
  , lookupAll
  , toGroups
  , hashKey
  ) where

import Data.Bits (xor)
import Data.Char (ord)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import qualified Data.Text as T

import MiniSQL.Value

-- | Buckets of distinct keys, each with its payloads in insertion order.
newtype HashTable a = HashTable (IntMap [([Value], [a])])

-- | Hash a key so that keys that compare equal hash equally (an INTEGER and
-- the REAL with the same value included).
hashKey :: [Value] -> Int
hashKey = foldl' (\h v -> (h * 1000003) `xor` hashValue v) 0x2545F491

hashValue :: Value -> Int
hashValue VNull = 0
hashValue (VInt n) = n
hashValue (VReal h)
  | h `mod` 100 == 0 = h `div` 100
  | otherwise = h * 7 + 1
hashValue (VText t) = T.foldl' (\h c -> (h * 33) `xor` ord c) 5381 t

-- | Build a table from @(key, payload)@ pairs. Payloads under one key keep
-- their order in the input.
fromPairs :: [([Value], a)] -> HashTable a
fromPairs pairs = HashTable (IntMap.map (map (fmap reverse)) built)
  where
    built = foldl' step IntMap.empty pairs
    step m (k, a) = IntMap.alter (Just . insertInto k a) (hashKey k) m
    insertInto k a Nothing = [(k, [a])]
    insertInto k a (Just bucket) = go bucket
      where
        go [] = [(k, [a])]
        go ((k', as) : rest)
          | sameKey k k' = (k', a : as) : rest
          | otherwise = (k', as) : go rest

-- | All payloads stored under a key, in insertion order.
lookupAll :: [Value] -> HashTable a -> [a]
lookupAll k (HashTable m) = case IntMap.lookup (hashKey k) m of
  Nothing -> []
  Just bucket -> case [as | (k', as) <- bucket, sameKey k k'] of
    (as : _) -> as
    [] -> []

-- | Every distinct key with its payloads (in unspecified key order).
toGroups :: HashTable a -> [([Value], [a])]
toGroups (HashTable m) = concat (IntMap.elems m)

sameKey :: [Value] -> [Value] -> Bool
sameKey a b = compareRows a b == EQ
