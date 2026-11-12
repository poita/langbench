-- | The error type shared by every stage of statement processing.
module MiniSQL.Error
  ( Error (..)
  , errorMessage
  ) where

-- | Why a statement failed. The command-line tool prints a bare @error@ for
-- every constructor; the distinction and the message exist for library users.
data Error
  = SyntaxError String
  -- ^ The statement does not match the grammar (including invalid tokens).
  | SemanticError String
  -- ^ The statement parses but cannot run: unknown table or column,
  -- misplaced aggregate, wrong arity, ...
  deriving (Eq, Show)

-- | Human readable description of an error.
errorMessage :: Error -> String
errorMessage (SyntaxError m) = "syntax error: " ++ m
errorMessage (SemanticError m) = m
