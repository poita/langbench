-- | Union-find unification over the shared type graph.
module Language.TypeInfer.Unify
  ( Infer
  , unify
  ) where

import Control.Monad (unless, zipWithM_)
import Control.Monad.ST (ST)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT, throwE)

import Language.TypeInfer.Error
import Language.TypeInfer.Graph

-- | Inference computations: 'ST' with early exit on a 'TypeError'.
type Infer s = ExceptT TypeError (ST s)

-- | Unify two types, left to right: for @t1 -> t2@ against @s1 -> s2@, @t1@
-- is unified with @s1@ (completely) before @t2@ with @s2@. A variable is
-- bound only after an occurs check, which also lowers the levels of the
-- variables it reaches. Fails with 'Occurs' or 'Unify'.
unify :: Ctx s -> Ty s -> Ty s -> Infer s ()
unify ctx a0 b0 = do
  a <- lift (prune a0)
  b <- lift (prune b0)
  case (a, b) of
    (TyVar u, TyVar w) | sameVar u w -> pure ()
    (TyVar u, _) -> bind u b
    (_, TyVar w) -> bind w a
    (TyInt, TyInt) -> pure ()
    (TyBool, TyBool) -> pure ()
    (TyUnit, TyUnit) -> pure ()
    (TyNode m, TyNode n)
      | sameNode m n -> pure ()
      | otherwise -> do
          case (nodeShape m, nodeShape n) of
            (SFun a1 r1, SFun a2 r2) -> unify ctx a1 a2 >> unify ctx r1 r2
            (SList e1, SList e2) -> unify ctx e1 e2
            (STuple xs, STuple ys)
              | length xs == length ys -> zipWithM_ (unify ctx) xs ys
            _ -> throwE Unify
          lift (linkNodes m n)
    _ -> throwE Unify
  where
    bind v t = do
      ok <- lift (bindVar ctx v t)
      unless ok (throwE Occurs)
