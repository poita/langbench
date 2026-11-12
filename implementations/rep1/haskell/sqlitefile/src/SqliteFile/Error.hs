-- | The error type shared by every layer of the library.
module SqliteFile.Error
  ( SqliteError (..)
  , corrupt
  , queryError
  ) where

import Control.Exception (Exception, throw)

-- | Everything that can go wrong.
--
-- 'CorruptDatabase' is raised (as an exception, from pure code) when the file
-- is not a valid database or a page/record is malformed. 'QueryError' means
-- the query text or the objects it names are invalid.
data SqliteError
  = CorruptDatabase String
  | QueryError String
  deriving (Eq, Show)

instance Exception SqliteError

-- | Throw a 'CorruptDatabase' from pure code.
corrupt :: String -> a
corrupt = throw . CorruptDatabase

-- | Throw a 'QueryError' from pure code.
queryError :: String -> a
queryError = throw . QueryError
