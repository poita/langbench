-- | A small in-memory relational database speaking a subset of SQLite's SQL
-- dialect.
--
-- The typical entry points are 'runScript' (execute a whole script and get
-- one 'Response' per statement that prints something) and 'renderScript'
-- (the exact text the command-line tool prints). For finer control use
-- 'parseScript' and 'execute' on a 'Database' value.
--
-- > import MiniSQL
-- > import qualified Data.Text.Lazy as TL
-- >
-- > main :: IO ()
-- > main = putStr (TL.unpack (renderScript (T.pack "CREATE TABLE t (x INTEGER); ...")))
module MiniSQL
  ( -- * Running scripts
    runScript
  , renderScript
  , Response (..)
  , renderResponse
    -- * Statements
  , parseScript
  , parseStatement
  , execute
  , Outcome (..)
    -- * Databases and values
  , Database
  , emptyDatabase
  , tableNames
  , Value (..)
  , renderValue
    -- * Errors
  , Error (..)
  , errorMessage
  ) where

import Data.List (mapAccumL)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Builder as B

import MiniSQL.Database
import MiniSQL.Error
import MiniSQL.Execute
import MiniSQL.Parser
import MiniSQL.Value

-- | What a statement prints.
data Response
  = ResultRows [[Value]]
  -- ^ The rows of a successful @SELECT@.
  | Failed Error
  -- ^ A statement that failed (it left the database unchanged).
  deriving (Eq, Show)

-- | Execute a script statement by statement against a database. Returns the
-- final database and one 'Response' for every statement that produces
-- output (every @SELECT@ and every failed statement), in order.
runScript :: Database -> Text -> (Database, [Response])
runScript db0 src = (final, catMaybes responses)
  where
    (final, responses) = mapAccumL step db0 (parseScript src)
    step db parsed = case parsed >>= execute db of
      Left e -> (db, Just (Failed e))
      Right (Outcome db' rows) -> (db', ResultRows <$> rows)

-- | The text the command-line tool prints for a response: the tab-separated
-- rows followed by @-- N rows@, or a single line @error@.
renderResponse :: Response -> B.Builder
renderResponse (Failed _) = B.fromString "error\n"
renderResponse (ResultRows rows) =
  foldMap (\r -> mconcat (intersperse' (B.singleton '\t') (map (B.fromText . renderValue) r)) <> B.singleton '\n') rows
    <> B.fromString ("-- " ++ show (length rows) ++ " rows\n")
  where
    intersperse' _ [] = []
    intersperse' _ [x] = [x]
    intersperse' s (x : xs) = x : s : intersperse' s xs

-- | Run a script on an empty database and render everything it prints.
renderScript :: Text -> TL.Text
renderScript = B.toLazyText . foldMap renderResponse . snd . runScript emptyDatabase
