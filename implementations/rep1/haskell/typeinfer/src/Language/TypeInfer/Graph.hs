-- | The mutable type graph used by inference (Algorithm J).
--
-- Types are shared graphs in the 'ST' monad:
--
-- * type variables are union-find nodes carrying a /level/;
-- * constructed types (functions, tuples, lists) are 'Node's that may be
--   shared between many parents, so a type with a small number of distinct
--   nodes can have an exponentially large unfolding;
-- * every traversal (occurs check, generalisation, instantiation, freezing)
--   visits each distinct node once, using a per-walk stamp stored in the node.
--
-- Generalisation is level based (Rémy): see 'generalise'.
module Language.TypeInfer.Graph
  ( -- * Context
    Ctx
  , newCtx
  , Level
    -- * Types
  , Ty (..)
  , Shape (..)
  , Node
  , nodeShape
  , Var
  , freshVar
  , mkFun
  , mkTuple
  , mkList
  , prune
  , sameVar
  , sameNode
  , linkNodes
  , bindVar
    -- * Schemes
  , Scheme (..)
  , generalise
  , instantiate
    -- * Conversion
  , freeze
  , importScheme
  ) where

import Control.Monad (forM, replicateM)
import Control.Monad.ST (ST)
import Data.Array (Array, listArray, (!))
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IM
import Data.Maybe (fromMaybe, isNothing)
import Data.STRef

import Language.TypeInfer.Type (Type (..))

-- | Generalisation level. A @let@ right-hand side is inferred one level
-- deeper than its surroundings.
type Level = Int

-- | Supply of fresh identifiers and walk stamps for one inference session.
data Ctx s = Ctx
  { ctxNextId :: !(STRef s Int)
  , ctxStamp  :: !(STRef s Int)
  }

-- | Create a new context.
newCtx :: ST s (Ctx s)
newCtx = Ctx <$> newSTRef 0 <*> newSTRef 0

bump :: STRef s Int -> ST s Int
bump r = do
  n <- readSTRef r
  writeSTRef r $! n + 1
  pure n

-- | A fresh stamp identifying one graph walk.
newStamp :: Ctx s -> ST s Int
newStamp ctx = bump (ctxStamp ctx) >>= \n -> pure (n + 1)

-- | State of a type variable.
data VarState s
  = Unbound !Level
  | Link (Ty s)
  | Generic !Int
    -- ^ Quantified by a scheme; the number is its index in the scheme.

-- | A type variable (a union-find node).
data Var s = Var
  { varId    :: !Int
  , varState :: !(STRef s (VarState s))
  }

-- | Types as graphs.
data Ty s
  = TyInt
  | TyBool
  | TyUnit
  | TyVar !(Var s)
  | TyNode !(Node s)

-- | The structure of a constructed type.
data Shape s
  = SFun !(Ty s) !(Ty s)
  | STuple [Ty s]
  | SList !(Ty s)

-- | A constructed type node. Nodes can be forwarded to an equal node after a
-- successful unification ('linkNodes'), so that unifying two large shared
-- types that are equal as trees but distinct as graphs stays cheap.
data Node s = Node
  { nodeShape :: !(Shape s)
  , nodeFwd   :: !(STRef s (Maybe (Node s)))
  , nodeMark  :: !(STRef s (Mark s))
  }

-- | Per-walk memo stored in a node: the stamp of the walk and its result.
data Mark s = Mark !Int (MarkVal s)

data MarkVal s
  = NoVal
  | Inst (Maybe (Ty s))  -- ^ instantiation result; 'Nothing' = unchanged
  | Frozen Type

-- | A type scheme. 'Mono' schemes (nothing quantified) are used as they are.
data Scheme s
  = Mono (Ty s)
  | Poly !Int (Ty s)
    -- ^ @Poly n t@ quantifies over @n@ 'Generic' variables inside @t@.

------------------------------------------------------------------------------
-- Construction

-- | A fresh unbound variable at the given level.
freshVar :: Ctx s -> Level -> ST s (Ty s)
freshVar ctx lvl = do
  i <- bump (ctxNextId ctx)
  r <- newSTRef (Unbound lvl)
  pure (TyVar (Var i r))

mkNode :: Shape s -> ST s (Ty s)
mkNode sh = do
  f <- newSTRef Nothing
  m <- newSTRef (Mark 0 NoVal)
  pure (TyNode (Node sh f m))

-- | @a -> b@
mkFun :: Ty s -> Ty s -> ST s (Ty s)
mkFun a b = mkNode (SFun a b)

-- | A tuple type (two or more components).
mkTuple :: [Ty s] -> ST s (Ty s)
mkTuple = mkNode . STuple

-- | @t list@
mkList :: Ty s -> ST s (Ty s)
mkList = mkNode . SList

------------------------------------------------------------------------------
-- Representatives

-- | Follow forwarding of a node to its representative.
repr :: Node s -> ST s (Node s)
repr n = readSTRef (nodeFwd n) >>= \case
  Nothing -> pure n
  Just m -> do
    r <- repr m
    writeSTRef (nodeFwd n) (Just r)
    pure r

-- | Resolve a type to its representative: a bound variable is replaced by
-- what it is bound to, a forwarded node by its target. The result is never a
-- bound variable.
prune :: Ty s -> ST s (Ty s)
prune t = case t of
  TyVar v -> readSTRef (varState v) >>= \case
    Link t' -> do
      r <- prune t'
      writeSTRef (varState v) (Link r)
      pure r
    _ -> pure t
  TyNode n -> TyNode <$> repr n
  _ -> pure t

-- | Are two (unbound) variables the same?
sameVar :: Var s -> Var s -> Bool
sameVar a b = varState a == varState b

-- | Are two representative nodes the same node?
sameNode :: Node s -> Node s -> Bool
sameNode a b = nodeFwd a == nodeFwd b

-- | Forward the first representative node to the second. Call this only
-- after the two have been successfully unified (so they are equal).
linkNodes :: Node s -> Node s -> ST s ()
linkNodes a b = writeSTRef (nodeFwd a) (Just b)

------------------------------------------------------------------------------
-- Binding variables

-- | @bindVar ctx v t@ binds the unbound variable @v@ to @t@ unless @v@ occurs
-- in @t@, in which case it returns 'False' and changes nothing that matters
-- (the failed unification is abandoned by the caller). While checking, the
-- levels of all variables reached in @t@ are lowered to @v@'s level.
bindVar :: Ctx s -> Var s -> Ty s -> ST s Bool
bindVar ctx v t0 = readSTRef (varState v) >>= \case
  Unbound lvl -> do
    stamp <- newStamp ctx
    occurs <- walk stamp lvl t0
    if occurs then pure False else writeSTRef (varState v) (Link t0) >> pure True
  _ -> error "Language.TypeInfer.Graph.bindVar: variable is not unbound"
  where
    -- Returns True if v occurs in the type.
    walk stamp lvl t = prune t >>= \case
      TyVar u
        | sameVar u v -> pure True
        | otherwise -> do
            readSTRef (varState u) >>= \case
              Unbound l | l > lvl -> writeSTRef (varState u) (Unbound lvl)
              _ -> pure ()
            pure False
      TyNode n -> do
        seen <- visited stamp n
        if seen then pure False else case nodeShape n of
          SFun a b -> walk stamp lvl a >>= \o -> if o then pure True else walk stamp lvl b
          SList e -> walk stamp lvl e
          STuple ts -> anyM (walk stamp lvl) ts
      _ -> pure False

anyM :: (a -> ST s Bool) -> [a] -> ST s Bool
anyM _ [] = pure False
anyM f (x : xs) = f x >>= \b -> if b then pure True else anyM f xs

-- | Mark a node as visited in this walk; True if it already was.
visited :: Int -> Node s -> ST s Bool
visited stamp n = do
  Mark s _ <- readSTRef (nodeMark n)
  if s == stamp then pure True else writeSTRef (nodeMark n) (Mark stamp NoVal) >> pure False

------------------------------------------------------------------------------
-- Generalisation and instantiation

-- | @generalise ctx lvl t@ quantifies every unbound variable of @t@ whose
-- level is greater than @lvl@ (Rémy's level-based generalisation: the
-- environment is never scanned, because variables that escape into it have
-- had their levels lowered by unification). Visits each node of @t@ once.
generalise :: Ctx s -> Level -> Ty s -> ST s (Scheme s)
generalise ctx lvl t0 = do
  stamp <- newStamp ctx
  count <- newSTRef (0 :: Int)
  let walk t = prune t >>= \case
        TyVar u -> readSTRef (varState u) >>= \case
          Unbound l | l > lvl -> do
            k <- readSTRef count
            writeSTRef count $! k + 1
            writeSTRef (varState u) (Generic k)
          _ -> pure ()
        TyNode n -> do
          seen <- visited stamp n
          if seen then pure () else case nodeShape n of
            SFun a b -> walk a >> walk b
            SList e -> walk e
            STuple ts -> mapM_ walk ts
        _ -> pure ()
  walk t0
  n <- readSTRef count
  pure (if n == 0 then Mono t0 else Poly n t0)

-- | Instantiate a scheme with fresh variables at the given level. Sub-terms
-- without quantified variables are shared with the scheme's type; each
-- distinct node is copied at most once.
instantiate :: Ctx s -> Level -> Scheme s -> ST s (Ty s)
instantiate _ _ (Mono t) = pure t
instantiate ctx lvl (Poly n t) = do
  vars <- replicateM n (freshVar ctx lvl)
  let arr = listArray (0, n - 1) vars
  stamp <- newStamp ctx
  fromMaybe t <$> inst arr stamp t

inst :: Array Int (Ty s) -> Int -> Ty s -> ST s (Maybe (Ty s))
inst arr stamp t = case t of
  TyVar v -> readSTRef (varState v) >>= \case
    Generic k -> pure (Just (arr ! k))
    Link t' -> inst arr stamp t'
    Unbound _ -> pure Nothing
  TyNode n0 -> do
    n <- repr n0
    Mark s val <- readSTRef (nodeMark n)
    case val of
      Inst r | s == stamp -> pure r
      _ -> do
        r <- case nodeShape n of
          SFun a b -> do
            a' <- inst arr stamp a
            b' <- inst arr stamp b
            if isNothing a' && isNothing b'
              then pure Nothing
              else Just <$> mkFun (fromMaybe a a') (fromMaybe b b')
          SList e -> do
            e' <- inst arr stamp e
            case e' of
              Nothing -> pure Nothing
              Just x -> Just <$> mkList x
          STuple ts -> do
            ts' <- mapM (inst arr stamp) ts
            if all isNothing ts'
              then pure Nothing
              else Just <$> mkTuple (zipWith fromMaybe ts ts')
        writeSTRef (nodeMark n) (Mark stamp (Inst r))
        pure r
  _ -> pure Nothing

------------------------------------------------------------------------------
-- Conversion to and from plain types

-- | Convert a graph type to a plain 'Type', numbering variables @0, 1, ...@
-- in order of first appearance (left to right). The result shares structure
-- with the graph, so it stays small when the graph is small, but printing it
-- unfolds it fully.
freeze :: Ctx s -> Ty s -> ST s Type
freeze ctx t0 = do
  stamp <- newStamp ctx
  names <- newSTRef (IM.empty :: IntMap Int)
  let go t = prune t >>= \case
        TyInt -> pure TInt
        TyBool -> pure TBool
        TyUnit -> pure TUnit
        TyVar v -> do
          m <- readSTRef names
          case IM.lookup (varId v) m of
            Just i -> pure (TVar i)
            Nothing -> do
              let i = IM.size m
              writeSTRef names (IM.insert (varId v) i m)
              pure (TVar i)
        TyNode n -> do
          Mark s val <- readSTRef (nodeMark n)
          case val of
            Frozen r | s == stamp -> pure r
            _ -> do
              r <- case nodeShape n of
                SFun a b -> TFun <$> go a <*> go b
                SList e -> TList <$> go e
                STuple ts -> TTuple <$> mapM go ts
              writeSTRef (nodeMark n) (Mark stamp (Frozen r))
              pure r
  go t0

-- | Build a scheme from a plain type, quantifying over all of its variables.
importScheme :: Ctx s -> Type -> ST s (Scheme s)
importScheme ctx ty = do
  let vs = distinct (vars ty)
  pairs <- forM (zip [0 ..] vs) $ \(k, v) -> do
    i <- bump (ctxNextId ctx)
    r <- newSTRef (Generic k)
    pure (v, TyVar (Var i r))
  let table = IM.fromList pairs
  t <- build table ty
  pure (if null vs then Mono t else Poly (length vs) t)
  where
    vars = \case
      TVar i -> [i]
      TFun a b -> vars a ++ vars b
      TTuple ts -> concatMap vars ts
      TList e -> vars e
      _ -> []
    distinct = reverse . foldl (\acc x -> if x `elem` acc then acc else x : acc) []
    build table = \case
      TInt -> pure TyInt
      TBool -> pure TyBool
      TUnit -> pure TyUnit
      TVar i -> pure (table IM.! i)
      TFun a b -> do
        a' <- build table a
        b' <- build table b
        mkFun a' b'
      TTuple ts -> mapM (build table) ts >>= mkTuple
      TList e -> build table e >>= mkList

