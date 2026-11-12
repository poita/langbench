-- | Binding and execution of @SELECT@.
module MiniSQL.Select (runSelect) where

import Control.Monad (unless, when)
import Data.Array ((!))
import Data.List (findIndex, nub, sortBy)
import Data.Maybe (fromMaybe)
import Data.Text (Text)

import MiniSQL.Bound
import MiniSQL.Database
import MiniSQL.Error
import MiniSQL.Eval
import MiniSQL.Hash
import MiniSQL.Syntax
import MiniSQL.Value

-- | Where an @ORDER BY@ term gets its sort key from.
data SortKey
  = KeyOutput Int
  -- ^ The value of an output column.
  | KeyExpr BExpr

-- | Run a @SELECT@ and return its result rows.
runSelect :: Database -> Select -> Either Error [[Value]]
runSelect db sel = do
  tables <- mapM (lookupTable db . trName) (selFrom sel)
  let names = [fromMaybe (trName r) (trAlias r) | r <- selFrom sel]
  unless (length (nub names) == length names) $
    Left (SemanticError "two tables in FROM have the same name")
  let scope = Scope (zipWith3 ScopeTable names (map tableColumns tables) (scanl (+) 0 (map (length . tableColumns) tables)))

  -- Filters: WHERE and ON are ANDed, and may not contain aggregates.
  filters <- traverse (bindExpr scope Scalar) (concatMap (maybe [] pure) [selJoinOn sel, selWhere sel])
  let conjuncts = concatMap splitConjuncts filters

  -- Is this an aggregate query?
  let itemExprs = [e | Item e _ <- selItems sel]
      orderExprs = [e | OrderTerm (OrdExpr e) _ <- selOrderBy sel]
      aggregateQuery =
        not (null (selGroupBy sel))
          || any hasAggregate (itemExprs ++ orderExprs ++ maybe [] pure (selHaving sel))
  groupCols <- mapM (\(ColumnRef q n) -> resolveColumn scope q n) (selGroupBy sel)
  let mode = if aggregateQuery then Grouped groupCols else Scalar

  -- Select list.
  items <- concat <$> mapM (bindItem scope mode) (selItems sel)
  having <- traverse (bindExpr scope mode) (selHaving sel)

  -- ORDER BY.
  let width = length items
  keys <- mapM (bindOrderTerm scope mode items width) (selOrderBy sel)

  -- Execution.
  let rows = sourceRows scope (map tableRows tables) conjuncts
      groups
        | not aggregateQuery = [Env r [] | r <- rows]
        | null groupCols = [groupEnv rows]
        | otherwise = map (groupEnv . snd) (sortBy (\a b -> compareRows (fst a) (fst b)) (toGroups (fromPairs [([r ! i | i <- groupCols], r) | r <- rows])))
      kept = maybe groups (\h -> filter (`isTrue` h) groups) having
      produced = [(out, [sortValue out env k | k <- map fst keys]) | env <- kept, let out = [eval env e | (e, _) <- items]]
      sorted
        | null keys = produced
        | otherwise = sortBy (compareKeys (map snd keys)) produced
      dropped = maybe id (drop . max 0) (selOffset sel) sorted
      limited = maybe id take (selLimit sel) dropped
  Right (map fst limited)
  where
    groupEnv rs = Env (case rs of (r : _) -> r; [] -> emptyRow) rs

    sortValue out env k = case k of
      KeyOutput i -> out !! i
      KeyExpr e -> eval env e

    compareKeys descs (_, a) (_, b) =
      mconcat (zipWith3 (\d x y -> if d then compareValues y x else compareValues x y) descs a b)

-- | Bind one select-list entry; @*@ expands to every column.
bindItem :: Scope -> Mode -> SelectItem -> Either Error [(BExpr, Maybe Text)]
bindItem scope@(Scope tables) mode item = case item of
  Star -> do
    when (null tables) $ Left (SemanticError "* requires a FROM clause")
    traverse (\i -> (\e -> (e, Nothing)) <$> checkGrouped i) [0 .. scopeWidth scope - 1]
  Item e alias -> (\b -> [(b, alias)]) <$> bindExpr scope mode e
  where
    checkGrouped i = case mode of
      Grouped gs | i `notElem` gs -> Left (SemanticError "column must be grouped or aggregated")
      _ -> Right (BCol i)

-- | Resolve an @ORDER BY@ term to a sort key and its direction.
bindOrderTerm :: Scope -> Mode -> [(BExpr, Maybe Text)] -> Int -> OrderTerm -> Either Error (SortKey, Bool)
bindOrderTerm scope mode items width (OrderTerm key desc) = do
  k <- case key of
    OrdOrdinal n
      | n >= 1 && n <= width -> Right (KeyOutput (n - 1))
      | otherwise -> Left (SemanticError "ORDER BY position out of range")
    OrdName n -> case findIndex ((== Just n) . snd) items of
      Just i -> Right (KeyOutput i)
      Nothing -> KeyExpr <$> bindExpr scope mode (ECol Nothing n)
    OrdExpr e -> KeyExpr <$> bindExpr scope mode e
  Right (k, desc)

-- | The rows that survive FROM, ON and WHERE, in nested-loop order.
sourceRows :: Scope -> [[Row]] -> [BExpr] -> [Row]
sourceRows (Scope scopeTables) tableRowss conjuncts = case tableRowss of
  [] -> [r | r <- [emptyRow], all (isTrue (rowEnv r)) conjuncts]
  [rs] -> [r | r <- rs, all (isTrue (rowEnv r)) conjuncts]
  [as, bs] -> joinRows (stOffset (scopeTables !! 1)) as bs conjuncts
  _ -> []

-- | Join two tables. Conjuncts that read one table filter it first; the
-- cross-table equalities form one composite hash key; the remaining
-- conjuncts filter the combined rows. Without a usable equality this is a
-- plain nested loop over the filtered rows. Either way the output is in
-- nested-loop order.
joinRows :: Int -> [Row] -> [Row] -> [BExpr] -> [Row]
joinRows split as bs conjuncts = case equalities of
  [] -> [c | a <- as', b <- bs', let c = combine a b, residualOk c]
  _ ->
    let table = fromPairs [(map (evalOn b) bKeys, b) | b <- bs']
     in [ c
        | a <- as'
        , let key = map (evalOn a) aKeys
        , VNull `notElem` key
        , b <- lookupAll key table
        , let c = combine a b
        , residualOk c
        ]
  where
    onlyA e = all (< split) (exprColumns e)
    onlyB e = not (null cs) && all (>= split) cs where cs = exprColumns e

    (leftOnly, rest1) = partitionBy onlyA conjuncts
    (rightOnly, cross) = partitionBy onlyB rest1
    equalities = [(l, r) | Just (l, r) <- map equality cross]
    residual = [c | c <- cross, equality c == Nothing]

    equality (BCmp Eq l r)
      | all (< split) lc && not (null lc) && all (>= split) rc && not (null rc) = Just (l, shift r)
      | all (< split) rc && not (null rc) && all (>= split) lc && not (null lc) = Just (r, shift l)
      where
        lc = exprColumns l
        rc = exprColumns r
        shift = mapColumns (subtract split)
    equality _ = Nothing

    aKeys = map fst equalities
    bKeys = map snd equalities

    as' = [a | a <- as, all (isTrue (rowEnv a)) leftOnly]
    bs' = [b | b <- bs, all (isTrue (rowEnv b)) (map (mapColumns (subtract split)) rightOnly)]

    evalOn r e = eval (rowEnv r) e
    combine a b = mkRow (rowToList a ++ rowToList b)
    residualOk c = all (isTrue (rowEnv c)) residual

    partitionBy p xs = (filter p xs, filter (not . p) xs)
