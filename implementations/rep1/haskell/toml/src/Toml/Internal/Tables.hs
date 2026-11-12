-- | The table-resolution layer of the decoder: it enforces TOML's rules about
-- which tables may be reopened, extended or redefined (SPEC §1.3).
module Toml.Internal.Tables
  ( Kind (..)
  , Tbl (..)
  , Node (..)
  , emptyTbl
  , openTable
  , openArray
  , insertKV
  , nodeToValue
  , tblToTable
  ) where

import Data.Foldable (toList)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Data.Text (Text)

import Toml.Value (Table, Value (..))

-- | How a table came into existence.
data Kind
  = Explicit  -- ^ opened by a @[header]@ (or the root)
  | Implicit  -- ^ created as an intermediate segment of a header
  | Dotted    -- ^ created as an intermediate segment of a dotted key
  | Inline    -- ^ an inline-table literal (closed)
  deriving (Eq, Show)

data Tbl = Tbl !Kind !(Map Text Node)

data Node
  = Leaf Value          -- ^ scalar or array literal
  | Sub Tbl             -- ^ a table
  | Tables (Seq Tbl)    -- ^ an array of tables built with @[[…]]@

emptyTbl :: Kind -> Tbl
emptyTbl k = Tbl k Map.empty

-- | Resolve all but the last segment of a header path, creating missing
-- tables of the given kind, then apply the function to the table reached.
descend
  :: Kind              -- ^ kind for newly created tables
  -> (Kind -> Bool)    -- ^ which existing tables may be passed through
  -> Bool              -- ^ may an array of tables be passed through (last element)?
  -> [Text]
  -> (Tbl -> Either String Tbl)
  -> Tbl -> Either String Tbl
descend _ _ _ [] f t = f t
descend new ok aot (k : ks) f (Tbl kind m) = case Map.lookup k m of
  Nothing -> do
    c <- descend new ok aot ks f (emptyTbl new)
    pure (Tbl kind (Map.insert k (Sub c) m))
  Just (Sub c@(Tbl ck _))
    | ok ck -> do
        c' <- descend new ok aot ks f c
        pure (Tbl kind (Map.insert k (Sub c') m))
    | otherwise -> Left ("cannot extend table " ++ show k)
  Just (Tables s)
    | aot, Seq.length s > 0 -> do
        let i = Seq.length s - 1
        c' <- descend new ok aot ks f (Seq.index s i)
        pure (Tbl kind (Map.insert k (Tables (Seq.update i c' s)) m))
  Just _ -> Left ("key " ++ show k ++ " is not a table")

notInline :: Kind -> Bool
notInline k = k /= Inline

-- | Apply a header-style descent to a non-empty path.
splitLast :: [Text] -> ([Text], Text)
splitLast ks = (init ks, last ks)

-- | @[a.b.c]@
openTable :: [Text] -> Tbl -> Either String Tbl
openTable path root = descend Implicit notInline True front final root
  where
    (front, k) = splitLast path
    final (Tbl kind m) = case Map.lookup k m of
      Nothing -> Right (Tbl kind (Map.insert k (Sub (emptyTbl Explicit)) m))
      Just (Sub (Tbl Implicit c)) -> Right (Tbl kind (Map.insert k (Sub (Tbl Explicit c)) m))
      Just _ -> Left ("table " ++ show k ++ " is already defined")

-- | @[[a.b.c]]@
openArray :: [Text] -> Tbl -> Either String Tbl
openArray path root = descend Implicit notInline True front final root
  where
    (front, k) = splitLast path
    final (Tbl kind m) = case Map.lookup k m of
      Nothing -> Right (Tbl kind (Map.insert k (Tables (Seq.singleton (emptyTbl Explicit))) m))
      Just (Tables s) -> Right (Tbl kind (Map.insert k (Tables (s |> emptyTbl Explicit)) m))
      Just _ -> Left ("key " ++ show k ++ " is already defined")

-- | Insert @key.path = node@ into the table reached by the current header
-- path.
insertKV :: [Text] -> [Text] -> Node -> Tbl -> Either String Tbl
insertKV current ks node =
  descend Implicit notInline True current $
    descend Dotted dottedOk False front final
  where
    (front, k) = splitLast ks
    dottedOk kind = kind == Dotted || kind == Implicit
    final (Tbl kind m)
      | Map.member k m = Left ("duplicate key " ++ show k)
      | otherwise = Right (Tbl kind (Map.insert k node m))

nodeToValue :: Node -> Value
nodeToValue (Leaf v) = v
nodeToValue (Sub t) = VTable (tblToTable t)
nodeToValue (Tables s) = VArray [VTable (tblToTable t) | t <- toList s]

tblToTable :: Tbl -> Table
tblToTable (Tbl _ m) = Map.map nodeToValue m
