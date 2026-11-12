-- | Error types shared by the parser and the type checker.
module Language.TypeInfer.Error
  ( -- * Source positions
    Pos (..)
    -- * Parse errors
  , ParseError (..)
  , renderParseError
    -- * Type errors
  , TypeError (..)
  , errorKind
  ) where

-- | A position in the source text (both components are 1-based).
data Pos = Pos
  { posLine :: !Int
  , posCol  :: !Int
  }
  deriving (Eq, Ord, Show)

-- | A lexical or syntactic error.
data ParseError = ParseError
  { parseErrorPos     :: !Pos
  , parseErrorMessage :: String
  }
  deriving (Eq, Show)

-- | Human-readable rendering, e.g. @3:14: expected ';;'@.
renderParseError :: ParseError -> String
renderParseError (ParseError (Pos l c) m) = show l ++ ":" ++ show c ++ ": " ++ m

-- | Why a declaration failed to type-check.
data TypeError
  = Unbound String
    -- ^ The named variable is not in scope.
  | Occurs
    -- ^ Unification would build an infinite type (e.g. @fun x -> x x@).
  | Unify
    -- ^ Any other unification failure (constructor clash, arity mismatch).
  deriving (Eq, Show)

-- | The short kind name used in the CLI output: @unbound@, @occurs@ or @unify@.
errorKind :: TypeError -> String
errorKind = \case
  Unbound _ -> "unbound"
  Occurs    -> "occurs"
  Unify     -> "unify"
