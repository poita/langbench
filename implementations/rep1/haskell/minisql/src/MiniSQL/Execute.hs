-- | Executing statements against a 'Database'.
module MiniSQL.Execute
  ( Outcome (..)
  , execute
  ) where

import Control.Monad (unless, when)
import Data.List (nub)
import Data.Text (Text)

import MiniSQL.Bound
import MiniSQL.Database
import MiniSQL.Error
import MiniSQL.Eval
import MiniSQL.Select
import MiniSQL.Syntax
import MiniSQL.Value

-- | The effect of a successfully executed statement.
data Outcome = Outcome
  { outcomeDatabase :: Database
  -- ^ The database after the statement.
  , outcomeRows :: Maybe [[Value]]
  -- ^ The result rows of a @SELECT@; 'Nothing' for every other statement.
  }

-- | Execute one statement. Binding and checking complete before anything is
-- changed, and the input database is never modified, so on 'Left' the
-- caller simply keeps the database it had.
execute :: Database -> Statement -> Either Error Outcome
execute db stmt = case stmt of
  CreateTable name cols -> do
    let names = map fst cols
    when (null cols) $ Left (SyntaxError "empty column list")
    unless (length (nub names) == length names) $ Left (SemanticError "duplicate column name")
    db' <- insertTable name (Table names []) db
    pure (Outcome db' Nothing)
  Insert name tuples -> do
    table <- lookupTable db name
    let scope = Scope []
        width = length (tableColumns table)
    rows <- mapM (insertRow scope width) tuples
    pure (Outcome (replaceTable name table {tableRows = tableRows table ++ rows} db) Nothing)
  Delete name wh -> do
    table <- lookupTable db name
    p <- traverse (bindExpr (tableScope name table) Scalar) wh
    let deleted r = maybe True (isTrue (rowEnv r)) p
        survivors = filter (not . deleted) (tableRows table)
    pure (Outcome (replaceTable name table {tableRows = survivors} db) Nothing)
  Update name sets wh -> do
    table <- lookupTable db name
    let scope = tableScope name table
    p <- traverse (bindExpr scope Scalar) wh
    targets <- mapM (\(c, e) -> (,) <$> resolveColumn scope Nothing c <*> bindExpr scope Scalar e) sets
    let change r
          | maybe True (isTrue (rowEnv r)) p =
              let env = rowEnv r
                  updates = [(i, eval env e) | (i, e) <- targets]
               in mkRow [maybe v id (lookup i updates) | (i, v) <- zip [0 ..] (rowToList r)]
          | otherwise = r
    pure (Outcome (replaceTable name table {tableRows = map change (tableRows table)} db) Nothing)
  SelectStmt sel -> do
    rows <- runSelect db sel
    pure (Outcome db (Just rows))
  where
    tableScope :: Text -> Table -> Scope
    tableScope n t = singleTableScope n (tableColumns t)

    insertRow scope width exprs = do
      when (length exprs /= width) $
        Left (SemanticError ("expected " ++ show width ++ " values, got " ++ show (length exprs)))
      bound <- mapM (bindExpr scope Scalar) exprs
      pure (mkRow [eval (rowEnv emptyRow) e | e <- bound])
