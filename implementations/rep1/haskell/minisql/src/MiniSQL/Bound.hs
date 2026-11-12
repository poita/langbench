-- | Name resolution. Binding turns a syntax-tree expression into a 'BExpr'
-- in which every column reference is an index into the current row, and
-- runs every semantic check (unknown or ambiguous columns, misplaced
-- aggregates, non-grouped columns).
module MiniSQL.Bound
  ( BExpr (..)
  , Scope (..)
  , ScopeTable (..)
  , Mode (..)
  , scopeWidth
  , singleTableScope
  , resolveColumn
  , bindExpr
  , exprColumns
  , mapColumns
  , splitConjuncts
  ) where

import Data.List (findIndices)
import Data.Text (Text)
import qualified Data.Text as T

import MiniSQL.Error
import MiniSQL.Syntax
import MiniSQL.Value

-- | An expression whose columns have been resolved.
data BExpr
  = BLit !Value
  | BCol !Int
  | BNeg BExpr
  | BArith ArithOp BExpr BExpr
  | BCmp CmpOp BExpr BExpr
  | BAnd BExpr BExpr
  | BOr BExpr BExpr
  | BNot BExpr
  | BIsNull BExpr
  | BLike BExpr BExpr
  | BAgg AggFn (Maybe BExpr)
  deriving (Eq, Show)

-- | A table visible to an expression: its effective name (alias, else the
-- table name), its columns and where its columns start in the joined row.
data ScopeTable = ScopeTable
  { stName :: Text
  , stColumns :: [Text]
  , stOffset :: Int
  }
  deriving (Eq, Show)

-- | The tables of a FROM clause, in order.
newtype Scope = Scope [ScopeTable]
  deriving (Eq, Show)

-- | Total number of columns of the joined row.
scopeWidth :: Scope -> Int
scopeWidth (Scope ts) = sum (map (length . stColumns) ts)

-- | The scope of a single table under its own name.
singleTableScope :: Text -> [Text] -> Scope
singleTableScope n cs = Scope [ScopeTable n cs 0]

-- | What kind of expression is being bound.
data Mode
  = Scalar
  -- ^ Evaluated per row; aggregates are errors.
  | Grouped [Int]
  -- ^ Evaluated per group; aggregates are allowed and a column outside one
  -- must be among the given grouping column indexes.
  deriving (Eq, Show)

-- | Resolve a possibly qualified column name to a joined-row index.
resolveColumn :: Scope -> Maybe Text -> Text -> Either Error Int
resolveColumn (Scope tables) qual name = case qual of
  Nothing -> case concatMap (matches name) tables of
    [i] -> Right i
    [] -> Left (SemanticError ("no such column: " ++ T.unpack name))
    _ -> Left (SemanticError ("ambiguous column: " ++ T.unpack name))
  Just q -> case filter ((== q) . stName) tables of
    [t] -> case matches name t of
      [i] -> Right i
      _ -> Left (SemanticError ("no such column: " ++ T.unpack q ++ "." ++ T.unpack name))
    _ -> Left (SemanticError ("no such table: " ++ T.unpack q))
  where
    matches n t = [stOffset t + i | i <- findIndices (== n) (stColumns t)]

-- | Bind an expression in the given scope and mode.
bindExpr :: Scope -> Mode -> Expr -> Either Error BExpr
bindExpr scope mode = go
  where
    go e = case e of
      EInt n -> Right (BLit (VInt n))
      EStr s -> Right (BLit (VText s))
      ENull -> Right (BLit VNull)
      ECol q n -> do
        i <- resolveColumn scope q n
        case mode of
          Grouped gs | i `notElem` gs -> Left (SemanticError ("column must be grouped or aggregated: " ++ T.unpack n))
          _ -> Right (BCol i)
      ENeg a -> BNeg <$> go a
      EArith op a b -> BArith op <$> go a <*> go b
      ECmp op a b -> BCmp op <$> go a <*> go b
      EAnd a b -> BAnd <$> go a <*> go b
      EOr a b -> BOr <$> go a <*> go b
      ENot a -> BNot <$> go a
      EIsNull a -> BIsNull <$> go a
      ELike a b -> BLike <$> go a <*> go b
      EAgg fn arg -> case mode of
        Scalar -> Left (SemanticError "aggregate function not allowed here")
        Grouped _ -> BAgg fn <$> traverse (bindExpr scope Scalar) arg

-- | Every column index an expression mentions (with repeats).
exprColumns :: BExpr -> [Int]
exprColumns e = case e of
  BCol i -> [i]
  BLit _ -> []
  BNeg a -> exprColumns a
  BArith _ a b -> exprColumns a ++ exprColumns b
  BCmp _ a b -> exprColumns a ++ exprColumns b
  BAnd a b -> exprColumns a ++ exprColumns b
  BOr a b -> exprColumns a ++ exprColumns b
  BNot a -> exprColumns a
  BIsNull a -> exprColumns a
  BLike a b -> exprColumns a ++ exprColumns b
  BAgg _ a -> maybe [] exprColumns a

-- | Rewrite every column index.
mapColumns :: (Int -> Int) -> BExpr -> BExpr
mapColumns f = go
  where
    go e = case e of
      BCol i -> BCol (f i)
      BLit _ -> e
      BNeg a -> BNeg (go a)
      BArith op a b -> BArith op (go a) (go b)
      BCmp op a b -> BCmp op (go a) (go b)
      BAnd a b -> BAnd (go a) (go b)
      BOr a b -> BOr (go a) (go b)
      BNot a -> BNot (go a)
      BIsNull a -> BIsNull (go a)
      BLike a b -> BLike (go a) (go b)
      BAgg fn a -> BAgg fn (go <$> a)

-- | Split an expression into its top-level @AND@ conjuncts.
splitConjuncts :: BExpr -> [BExpr]
splitConjuncts (BAnd a b) = splitConjuncts a ++ splitConjuncts b
splitConjuncts e = [e]
