-- | The in-memory database: named tables holding rows in insertion order.
module MiniSQL.Database
  ( Table (..)
  , Database
  , emptyDatabase
  , lookupTable
  , tableNames
  , insertTable
  , replaceTable
  , forceRows
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T

import MiniSQL.Error
import MiniSQL.Value

-- | A table: its column names and its rows in insertion order.
data Table = Table
  { tableColumns :: [Text]
  , tableRows :: [Row]
  }
  deriving (Eq, Show)

-- | A set of tables keyed by (lower-case) name. A 'Database' is an immutable
-- value: every statement yields a new one, so a failing statement cannot
-- leave a half-applied change behind.
newtype Database = Database (Map Text Table)
  deriving (Eq, Show)

-- | A database with no tables.
emptyDatabase :: Database
emptyDatabase = Database Map.empty

-- | Find a table, or fail with a semantic error.
lookupTable :: Database -> Text -> Either Error Table
lookupTable (Database m) n = case Map.lookup n m of
  Just t -> Right t
  Nothing -> Left (SemanticError ("no such table: " ++ T.unpack n))

-- | The names of all tables, sorted.
tableNames :: Database -> [Text]
tableNames (Database m) = Map.keys m

-- | Add a new table; fails if the name is taken.
insertTable :: Text -> Table -> Database -> Either Error Database
insertTable n t (Database m)
  | Map.member n m = Left (SemanticError ("table already exists: " ++ T.unpack n))
  | otherwise = Right (Database (Map.insert n t m))

-- | Replace the contents of an existing table.
replaceTable :: Text -> Table -> Database -> Database
replaceTable n t (Database m) = Database (Map.insert n (t {tableRows = forceRows (tableRows t)}) m)

-- | Force the spine of a row list and every value in it, so that long
-- scripts do not accumulate chains of thunks.
forceRows :: [Row] -> [Row]
forceRows rs = foldl' (\() r -> foldl' (\() v -> v `seq` ()) () (rowToList r)) () rs `seq` rs
