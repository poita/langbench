-- | A deliberately naive, independent reference implementation of the
-- language, used to cross-check the engine on random programs: strata are
-- found by constraint relaxation, and each stratum is evaluated by naive
-- iteration over substitutions held in 'Map's.
module Reference
  ( referenceRun
  , renderProgram
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.List (intercalate)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import qualified Data.Set as S

import Datalog

type Env = M.Map ByteString Const

type Rel = M.Map PredKey (S.Set [Const])

-- | The answers of every query in order, or 'Nothing' for @error@.
referenceRun :: Program -> Maybe [[[Const]]]
referenceRun prog
  | not (all safe rules) = Nothing
  | otherwise = do
      strata <- stratumOf rules
      let model = foldl (evalStratum rules strata) M.empty [0 .. maximum (0 : M.elems strata)]
      Just [answer model q | q <- clauseQueries prog]
  where
    rules = clauseRules prog

safe :: Rule -> Bool
safe (Rule h body) = all ok (atomArgs h ++ concat [atomArgs a | Neg a <- body] ++ concat [[l, r] | Cmp _ l r <- body])
  where
    bound = [v | Pos a <- body, TVar v <- atomArgs a]
    ok (TVar v) = v `elem` bound
    ok TAnon = False
    ok _ = True

stratumOf :: [Rule] -> Maybe (M.Map PredKey Int)
stratumOf rules = go (length keys + 1) (M.fromList [(k, 0) | k <- keys])
  where
    keys = S.toList (S.fromList (concat [atomKey (ruleHead r) : [atomKey a | l <- ruleBody r, a <- lit l] | r <- rules]))
    lit (Pos a) = [a]
    lit (Neg a) = [a]
    lit _ = []
    constraints = [ (atomKey (ruleHead r), atomKey a, if isNeg l then 1 else 0)
                  | r <- rules, l <- ruleBody r, a <- lit l ]
    isNeg (Neg _) = True
    isNeg _ = False
    go :: Int -> M.Map PredKey Int -> Maybe (M.Map PredKey Int)
    go fuel s
      | s' == s = Just s
      | fuel == 0 = Nothing
      | otherwise = go (fuel - 1) s'
      where
        s' = foldl (\m (h, q, d) -> M.insertWith max h (m M.! q + d) m) s constraints

evalStratum :: [Rule] -> M.Map PredKey Int -> Rel -> Int -> Rel
evalStratum rules strata rel0 k = fixpoint rel0
  where
    mine = [r | r <- rules, strata M.! atomKey (ruleHead r) == k]
    fixpoint rel =
      let rel' = foldl addRule rel mine
       in if rel' == rel then rel else fixpoint rel'
    addRule rel r =
      let new = S.fromList [instantiate env (atomArgs (ruleHead r)) | env <- solve rel (ruleBody r)]
       in M.insertWith S.union (atomKey (ruleHead r)) new rel

instantiate :: Env -> [Term] -> [Const]
instantiate env = map f
  where
    f (TConst c) = c
    f (TVar v) = env M.! v
    f TAnon = error "anonymous variable in head"

solve :: Rel -> [Literal] -> [Env]
solve rel body = filter ok (foldl step [M.empty] [a | Pos a <- body])
  where
    step envs a = [e' | e <- envs, tup <- S.toList (tuples (atomKey a)), Just e' <- [unify e (atomArgs a) tup]]
    tuples key = fromMaybe S.empty (M.lookup key rel)
    ok env = all (check env) body
    check _ (Pos _) = True
    check env (Neg a) = instantiate env (atomArgs a) `S.notMember` tuples (atomKey a)
    check env (Cmp op l r) = evalCmp op (val env l) (val env r)
    val _ (TConst c) = c
    val env (TVar v) = env M.! v
    val _ TAnon = error "anonymous variable in comparison"

unify :: Env -> [Term] -> [Const] -> Maybe Env
unify env [] [] = Just env
unify env (t : ts) (c : cs) = case t of
  TConst c' | c == c' -> unify env ts cs
            | otherwise -> Nothing
  TAnon -> unify env ts cs
  TVar v -> case M.lookup v env of
    Just c' | c == c' -> unify env ts cs
            | otherwise -> Nothing
    Nothing -> unify (M.insert v c env) ts cs
unify _ _ _ = Nothing

answer :: Rel -> Atom -> [[Const]]
answer rel q = S.toAscList (S.filter (\t -> unify M.empty (atomArgs q) t /= Nothing) tuples)
  where tuples = fromMaybe S.empty (M.lookup (atomKey q) rel)

-- | Print a program as source text.
renderProgram :: Program -> ByteString
renderProgram = B.pack . unlines . map clause
  where
    clause (ClauseQuery a) = "?- " ++ atom a ++ "."
    clause (ClauseRule (Rule h [])) = atom h ++ "."
    clause (ClauseRule (Rule h b)) = atom h ++ " :- " ++ intercalate ", " (map lit b) ++ "."
    atom (Atom p as) = B.unpack p ++ "(" ++ intercalate ", " (map term as) ++ ")"
    lit (Pos a) = atom a
    lit (Neg a) = "not " ++ atom a
    lit (Cmp op l r) = term l ++ " " ++ opS op ++ " " ++ term r
    term (TConst (CInt n)) = show n
    term (TConst (CSym s)) = B.unpack s
    term (TVar v) = B.unpack v
    term TAnon = "_"
    opS OpLt = "<"
    opS OpLe = "<="
    opS OpGt = ">"
    opS OpGe = ">="
    opS OpEq = "="
    opS OpNe = "!="
