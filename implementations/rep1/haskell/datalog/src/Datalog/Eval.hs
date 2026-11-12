-- |
-- Module      : Datalog.Eval
-- Description : Semi-naive bottom-up evaluation of stratified programs.
--
-- 'evaluate' checks safety and stratification, numbers constants (in their
-- total order, so that comparison of constants is comparison of integers) and
-- predicates, compiles every rule into join 'Plan's and then evaluates the
-- strongly connected components of the dependency graph in dependency order.
--
-- A recursive component runs each rule once and then, round by round, one
-- variant of each rule per recursive positive atom, which reads that atom from
-- the previous round's new tuples; the other atoms read the relations as they
-- stood at the start of the round. Every relation keeps one index per access
-- pattern used by the plans; indexes are extended with each round's new tuples
-- and never rebuilt.
module Datalog.Eval
  ( Model
  , evaluate
  , queryModel
  , relationTuples
  ) where

import Control.Monad (unless)
import Control.Monad.ST (ST, runST)
import Data.Array (Array, listArray, (!))
import Data.Array.Base (unsafeRead, unsafeWrite)
import Data.Array.ST (STUArray, newArray)
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.List (mapAccumL)
import qualified Data.Map.Strict as M
import Data.STRef (modifySTRef', newSTRef, readSTRef)
import qualified Data.Set as S
import qualified Data.ByteString.Char8 as B

import Datalog.Analysis
import Datalog.Plan
import Datalog.Syntax
import qualified Datalog.Trie as T

-- | The perfect model of a program.
data Model = Model
  { modelConsts :: Array Int Const
  , modelConstIx :: M.Map Const Int
  , modelPreds :: M.Map PredKey PredId
  , modelRels :: IM.IntMap Relation
  }

-- | A relation: the full tuple set plus indexes by column permutation.
data Relation = Relation
  { relFull :: !T.Trie
  , relIdx :: !(M.Map [Int] T.Trie)
  }

type DB = IM.IntMap Relation

------------------------------------------------------------------------------
-- Top level

-- | Compute the perfect model of a program, or report why it has none.
-- Safety is checked first, then stratifiability.
evaluate :: Program -> Either Error Model
evaluate prog = do
  checkSafety rules
  comps <- stratify rules
  let constList = S.toAscList (S.fromList (concatMap clauseConsts prog))
      constIx = M.fromList (zip constList [0 ..])
      consts = listArray (0, length constList - 1) constList
      predKeys = S.toAscList (S.fromList (concatMap ruleKeys rules))
      predIx = M.fromList (zip predKeys [0 ..])
      arities = IM.fromList [(i, n) | ((_, n), i) <- zip predKeys [0 ..]]
      compiled = [(r, compileRule constIx predIx r) | r <- rules]
      factRows = [ (caPred (crHead cr), [c | OConst c <- caArgs (crHead cr)])
                 | (r, cr) <- compiled, null (ruleBody r) ]
      proper = [cr | (r, cr) <- compiled, not (null (ruleBody r))]
      cps = [compPlans comp proper predIx | comp <- comps]
      allPlans = concat [cpInitial cp ++ map snd (cpVariants cp) | cp <- cps]
      db0 = initialDB arities factRows (concatMap planIndexes allPlans)
      db = foldl' (flip (evalComponent arities)) db0 cps
  Right (Model consts constIx predIx db)
  where
    rules = clauseRules prog
    ruleKeys (Rule h body) = atomKey h : [atomKey a | l <- body, Just a <- [litAtom l]]
    clauseConsts (ClauseRule (Rule h body)) = atomConsts h ++ concatMap litConsts body
    clauseConsts (ClauseQuery a) = atomConsts a
    atomConsts a = [c | TConst c <- atomArgs a]
    litConsts (Pos a) = atomConsts a
    litConsts (Neg a) = atomConsts a
    litConsts (Cmp _ l r) = [c | TConst c <- [l, r]]

litAtom :: Literal -> Maybe Atom
litAtom (Pos a) = Just a
litAtom (Neg a) = Just a
litAtom _ = Nothing

-- | Plans of one component.
data CompPlans = CompPlans
  { cpRecursive :: Bool
  , cpInitial :: [Plan]
    -- ^ every rule once, all atoms read from the full relations
  , cpVariants :: [(PredId, Plan)]
    -- ^ delta variants: (predicate read as delta, plan)
  }

compPlans :: Component -> [CRule] -> M.Map PredKey PredId -> CompPlans
compPlans comp rules predIx = CompPlans (compRecursive comp) initial variants
  where
    ps = IS.fromList [predIx M.! k | k <- compPreds comp]
    mine = [r | r <- rules, IS.member (caPred (crHead r)) ps]
    initial = [planRule r Nothing | r <- mine]
    variants
      | compRecursive comp =
          [ (caPred a, planRule r (Just i))
          | r <- mine
          , (i, a) <- zip [0 ..] (crPositive r)
          , IS.member (caPred a) ps ]
      | otherwise = []

------------------------------------------------------------------------------
-- Compilation

compileRule :: M.Map Const Int -> M.Map PredKey PredId -> Rule -> CRule
compileRule constIx predIx (Rule h0 body0) =
  CRule
    { crHead = atom' h
    , crPositive = [atom' a | Pos a <- body]
    , crNegative = [atom' a | Neg a <- body]
    , crCompare = [(o, term l, term r) | Cmp o l r <- body]
    , crNumVars = M.size nameIx
    }
  where
    -- give every '_' a distinct name (variables never start with '_')
    (_, (h, body)) = renameRule h0 body0
    nameIx = M.fromList (zip (S.toAscList (S.fromList [v | t <- allTerms, TVar v <- [t]])) [0 ..])
    allTerms = atomArgs h ++ concatMap litTerms body
    litTerms (Pos a) = atomArgs a
    litTerms (Neg a) = atomArgs a
    litTerms (Cmp _ l r) = [l, r]
    atom' a = CAtom (predIx M.! atomKey a) (map term (atomArgs a))
    term (TConst c) = OConst (constIx M.! c)
    term (TVar v) = OVar (nameIx M.! v)
    term TAnon = error "compileRule: unnamed anonymous variable"

-- | Replace each @_@ by a fresh variable name @_0@, @_1@, ...
renameRule :: Atom -> [Literal] -> (Int, (Atom, [Literal]))
renameRule h body = (n2, (h', body'))
  where
    (n1, h') = anonAtom 0 h
    (n2, body') = mapAccumL anonLit n1 body
    anonLit n (Pos a) = Pos <$> anonAtom n a
    anonLit n (Neg a) = Neg <$> anonAtom n a
    anonLit n (Cmp o l r) = let (n', l') = anonTerm n l
                                (n'', r') = anonTerm n' r
                             in (n'', Cmp o l' r')
    anonAtom n (Atom p as) = let (n', as') = mapAccumL anonTerm n as in (n', Atom p as')
    anonTerm n TAnon = (n + 1, TVar (B.pack ('_' : show n)))
    anonTerm n t = (n, t)

------------------------------------------------------------------------------
-- Database

initialDB :: IM.IntMap Int -> [(PredId, [Int])] -> [(PredId, [Int])] -> DB
initialDB arities facts idxs = IM.mapWithKey build arities
  where
    factMap = IM.fromListWith (++) [(p, [t]) | (p, t) <- facts]
    permMap = IM.fromListWith S.union [(p, S.singleton perm) | (p, perm) <- idxs]
    build p n =
      let tuples = IM.findWithDefault [] p factMap
          full = T.fromList n tuples
          perms = S.toList (IM.findWithDefault S.empty p permMap)
       in Relation full (M.fromList [(pm, permuteTrie n pm full) | pm <- perms])

permuteTrie :: Int -> [Int] -> T.Trie -> T.Trie
permuteTrie n perm t = T.fromList n [[tup !! i | i <- perm] | tup <- T.toList t]

-- | Add new tuples (which must not already be present) to a relation.
addTuples :: Int -> T.Trie -> Relation -> Relation
addTuples n new (Relation full idx) =
  Relation (T.union full new) (M.mapWithKey (\perm t -> T.union t (permuteTrie n perm new)) idx)

relationFor :: DB -> PredId -> Relation
relationFor db p = db IM.! p

sourceTrie :: DB -> Source -> Maybe T.Trie -> T.Trie
sourceTrie _ Delta (Just d) = d
sourceTrie _ Delta Nothing = error "sourceTrie: no delta"
sourceTrie db (Full p perm) _
  | isIdentityPerm perm = relFull rel
  | otherwise = relIdx rel M.! perm
  where rel = relationFor db p

------------------------------------------------------------------------------
-- Evaluating a component

evalComponent :: IM.IntMap Int -> CompPlans -> DB -> DB
evalComponent arities cp db0
  | null (cpInitial cp) = db0
  | otherwise = loop db1 delta1
  where
    (db1, delta1) = applyRound arities db0 [(planHead p, runPlan db0 Nothing p) | p <- cpInitial cp]
    loop db delta
      | not (cpRecursive cp) || IM.null delta = db
      | otherwise =
          let results = [ (planHead p, runPlan db (Just d) p)
                        | (q, p) <- cpVariants cp
                        , Just d <- [IM.lookup q delta] ]
              (db', delta') = applyRound arities db results
           in loop db' delta'

-- | Merge the tuples derived in one round into the database; returns the new
-- database and, per predicate, the tuples that were new.
applyRound :: IM.IntMap Int -> DB -> [(PredId, T.Trie)] -> (DB, IM.IntMap T.Trie)
applyRound arities db results = (db', delta)
  where
    merged = IM.filter (not . T.null) (IM.fromListWith T.union results)
    delta = merged
    db' = IM.foldlWithKey' (\d p new -> IM.adjust (addTuples (arities IM.! p) new) p d) db merged

------------------------------------------------------------------------------
-- Executing a plan

data RStep
  = RScan [Level] T.Trie
  | RNot [Operand] T.Trie
  | RCmp CmpOp Operand Operand

-- | Run a plan against the database (reading the delta atom, if any, from the
-- given trie) and return the head tuples that are not yet in the head's
-- relation.
runPlan :: DB -> Maybe T.Trie -> Plan -> T.Trie
runPlan db mdelta plan = runST $ do
  env <- newArray (0, max 0 (planNumVars plan - 1)) 0 :: ST s (STUArray s Int Int)
  let headFull = relFull (relationFor db (planHead plan))
      arity = length (planHeadArgs plan)
  ref <- newSTRef (T.empty arity)
  let emit = do
        tup <- mapM (operand env) (planHeadArgs plan)
        unless (T.member tup headFull) $ modifySTRef' ref (T.insert tup)
  exec env (map resolve (planSteps plan)) emit
  readSTRef ref
  where
    resolve (SScan src lv) = RScan lv (sourceTrie db src mdelta)
    resolve (SNot p ops) = RNot ops (relFull (relationFor db p))
    resolve (SCmp o l r) = RCmp o l r

operand :: STUArray s Int Int -> Operand -> ST s Int
operand _ (OConst c) = return c
operand env (OVar v) = unsafeRead env v
{-# INLINE operand #-}

exec :: STUArray s Int Int -> [RStep] -> ST s () -> ST s ()
exec _ [] k = k
exec env (RScan lv t : rest) k = walk env lv t (exec env rest k)
exec env (RNot ops t : rest) k = do
  tup <- mapM (operand env) ops
  unless (T.member tup t) (exec env rest k)
exec env (RCmp o l r : rest) k = do
  a <- operand env l
  b <- operand env r
  if evalCmp o a b then exec env rest k else return ()

-- | Match the columns of a trie against levels, running the continuation for
-- every consistent binding.
walk :: STUArray s Int Int -> [Level] -> T.Trie -> ST s () -> ST s ()
walk env [lv] (T.Leaf s) k = case lv of
  LBind v -> IS.foldr (\x rest -> unsafeWrite env v x >> k >> rest) (return ()) s
  _ -> do
    c <- level env lv
    if IS.member c s then k else return ()
walk env (lv : lvs) (T.Node m) k = case lv of
  LBind v -> IM.foldrWithKey (\x t rest -> unsafeWrite env v x >> walk env lvs t k >> rest) (return ()) m
  _ -> do
    c <- level env lv
    case IM.lookup c m of
      Just t -> walk env lvs t k
      Nothing -> return ()
walk _ _ _ _ = error "walk: arity mismatch"

level :: STUArray s Int Int -> Level -> ST s Int
level _ (LConst c) = return c
level env (LBound v) = unsafeRead env v
level env (LCheck v) = unsafeRead env v
level _ (LBind _) = error "level: LBind"
{-# INLINE level #-}

------------------------------------------------------------------------------
-- Querying

-- | All tuples of a predicate (by name and arity), in ascending order.
relationTuples :: Model -> PredKey -> [[Const]]
relationTuples m key = case M.lookup key (modelPreds m) of
  Nothing -> []
  Just p -> map (map (modelConsts m !)) (T.toList (relFull (relationFor (modelRels m) p)))

data QLevel = QConst !Int | QVar !Int

-- | Answer a query: the tuples of the atom's predicate that match it, in
-- ascending tuple order. Constants of the atom that do not occur anywhere in
-- the program match nothing; variables that occur several times must agree.
queryModel :: Model -> Atom -> [[Const]]
queryModel m a = case (M.lookup (atomKey a) (modelPreds m), mapM level' (zip [0 ..] (atomArgs a))) of
  (Just p, Just lvs) ->
    map (map (modelConsts m !)) (matchTrie lvs IM.empty [] (relFull (relationFor (modelRels m) p)))
  _ -> []
  where
    names = M.fromList (zip [v | TVar v <- atomArgs a] [0 :: Int ..])
    level' (_, TConst c) = QConst <$> M.lookup c (modelConstIx m)
    level' (_, TVar v) = Just (QVar (names M.! v))
    level' (i, TAnon) = Just (QVar (negate i - 1))

matchTrie :: [QLevel] -> IM.IntMap Int -> [Int] -> T.Trie -> [[Int]]
matchTrie [lv] env pre (T.Leaf s) = case lv of
  QConst c -> [reverse (c : pre) | IS.member c s]
  QVar v -> case IM.lookup v env of
    Just c -> [reverse (c : pre) | IS.member c s]
    Nothing -> [reverse (x : pre) | x <- IS.toAscList s]
matchTrie (lv : lvs) env pre (T.Node mp) = case lv of
  QConst c -> maybe [] (matchTrie lvs env (c : pre)) (IM.lookup c mp)
  QVar v -> case IM.lookup v env of
    Just c -> maybe [] (matchTrie lvs env (c : pre)) (IM.lookup c mp)
    Nothing -> [ r | (x, t) <- IM.toAscList mp, r <- matchTrie lvs (IM.insert v x env) (x : pre) t ]
matchTrie _ _ _ _ = []
