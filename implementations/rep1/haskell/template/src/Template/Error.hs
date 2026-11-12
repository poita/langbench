-- | The error kinds a load or render can fail with.
module Template.Error
  ( ErrorKind (..)
  , errorKindName
  , EvalError (..)
  ) where

import Control.Exception (Exception)

-- | Why loading or rendering a template failed.
data ErrorKind
  = ErrSyntax     -- ^ the template could not be lexed or parsed
  | ErrFilter     -- ^ an unknown filter name is used
  | ErrUndefined  -- ^ the undefined value was used in a forbidden way
  | ErrTemplate   -- ^ an @include@ or @extends@ names a missing template
  | ErrType       -- ^ an operand or argument has the wrong kind
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The name of an error kind as printed by the command-line tool.
errorKindName :: ErrorKind -> String
errorKindName k = case k of
  ErrSyntax -> "syntax"
  ErrFilter -> "filter"
  ErrUndefined -> "undefined"
  ErrTemplate -> "template"
  ErrType -> "type"

-- | Exception used internally by the interpreter to abort a render.
newtype EvalError = EvalError ErrorKind
  deriving (Show)

instance Exception EvalError
