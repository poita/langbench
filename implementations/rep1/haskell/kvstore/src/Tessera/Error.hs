-- | The error kinds of SPEC §18 and the exception that carries them.
module Tessera.Error
  ( ErrorKind (..)
  , errorName
  , TesseraError (..)
  , throwKind
  , attempt
  ) where

import Control.Exception (Exception, throwIO, try)

-- | Every way a command can fail.
data ErrorKind
  = Syntax
  | UnknownCommand
  | BadUtf8
  | IntRange
  | DupField
  | Depth
  | BadKey
  | BadPath
  | NotFound
  | NoField
  | NotObject
  | DocTooLarge
  | IndexKeyTooLong
  | IndexExists
  | IndexMissing
  | IndexLimit
  | TxnActive
  | NoTxn
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The spelling used in @results.txt@ (for example @"not-found"@).
errorName :: ErrorKind -> String
errorName k = case k of
  Syntax -> "syntax"
  UnknownCommand -> "unknown-command"
  BadUtf8 -> "bad-utf8"
  IntRange -> "int-range"
  DupField -> "dup-field"
  Depth -> "depth"
  BadKey -> "bad-key"
  BadPath -> "bad-path"
  NotFound -> "not-found"
  NoField -> "no-field"
  NotObject -> "not-object"
  DocTooLarge -> "doc-too-large"
  IndexKeyTooLong -> "index-key-too-long"
  IndexExists -> "index-exists"
  IndexMissing -> "index-missing"
  IndexLimit -> "index-limit"
  TxnActive -> "txn-active"
  NoTxn -> "no-txn"

-- | Exception used internally to abort an operation with an 'ErrorKind'.
newtype TesseraError = TesseraError ErrorKind
  deriving (Show)

instance Exception TesseraError

-- | Abort the current operation.
throwKind :: ErrorKind -> IO a
throwKind = throwIO . TesseraError

-- | Run an action, turning a 'TesseraError' into a 'Left'.
attempt :: IO a -> IO (Either ErrorKind a)
attempt act = either (\(TesseraError k) -> Left k) Right <$> try act
