-- |
-- Module      : Scheme.Eval
-- Description : Trampolined evaluator for analysed code.
--
-- 'step' evaluates a node in tail position: a procedure call there is not
-- performed but returned as a 'TailCall', and 'trampoline' performs it.
-- Loops written as tail calls therefore run in constant host stack, while
-- non-tail calls nest (the GHC stack is growable, so deep recursion works).
module Scheme.Eval
  ( eval
  , apply
  ) where

import Control.Exception (throwIO)
import Control.Monad (foldM)
import Data.IORef (newIORef)

import Scheme.Types

-- | Evaluate a node to a value.
eval :: Node -> Env -> IO Value
eval node env = case node of
  Const v -> pure v
  Ref s -> lookupVar s env
  _ -> step node env >>= trampoline

-- | Call a procedure value on arguments and run it to completion.
apply :: Value -> [Value] -> IO Value
apply f args = applyStep f args >>= trampoline

trampoline :: Step -> IO Value
trampoline (Done v) = pure v
trampoline (TailCall f args) = applyStep f args >>= trampoline

-- | Evaluate a node in tail position.
step :: Node -> Env -> IO Step
step node env = case node of
  Const v -> pure (Done v)
  Ref s -> Done <$> lookupVar s env
  Set s e -> do
    v <- eval e env
    assignVar s v env
    pure (Done VVoid)
  Define s e -> do
    v <- eval e env
    defineVar s v env
    pure (Done VVoid)
  If c t e -> do
    cv <- eval c env
    step (if isTrue cv then t else e) env
  Lambda params body -> Done <$> makeClosure params body env
  Let bs body -> do
    vs <- mapM (\(_, e) -> eval e env) bs
    env' <- newFrame env (zip (map fst bs) vs)
    stepBody body env'
  NamedLet name bs params body -> do
    vs <- mapM (\(_, e) -> eval e env) bs
    nameEnv <- newFrame env []
    clo <- makeClosure params body nameEnv
    defineVar name clo nameEnv
    pure (TailCall clo vs)
  LetStar bs body -> case bs of
    [] -> newFrame env [] >>= stepBody body
    _ -> do
      env' <- foldM (\e (s, i) -> eval i e >>= \v -> newFrame e [(s, v)]) env bs
      stepBody body env'
  Letrec bs body -> do
    env' <- newFrame env []
    mapM_ (\(s, e) -> eval e env' >>= \v -> defineVar s v env') bs
    stepBody body env'
  Begin body -> stepBody body env
  Cond clauses -> stepCond clauses env
  And xs -> stepAnd xs
  Or xs -> stepOr xs
  App f args -> do
    fv <- eval f env
    vs <- mapM (`eval` env) args
    pure (TailCall fv vs)
  where
    stepAnd [] = pure (Done (VBool True))
    stepAnd [x] = step x env
    stepAnd (x : xs) = do
      v <- eval x env
      if isTrue v then stepAnd xs else pure (Done v)
    stepOr [] = pure (Done (VBool False))
    stepOr [x] = step x env
    stepOr (x : xs) = do
      v <- eval x env
      if isTrue v then pure (Done v) else stepOr xs

stepBody :: Body -> Env -> IO Step
stepBody (xs, l) env = mapM_ (`eval` env) xs >> step l env

stepCond :: [Clause] -> Env -> IO Step
stepCond [] _ = pure (Done VVoid)
stepCond (Else body : _) env = stepBody body env
stepCond (Clause test body : rest) env = do
  v <- eval test env
  if isTrue v
    then maybe (pure (Done v)) (`stepBody` env) body
    else stepCond rest env

makeClosure :: Params -> Body -> Env -> IO Value
makeClosure params@(Params req _) body env = do
  t <- newIORef ()
  pure (VClosure (Closure t params (length req) body env))

-- | Perform a call: check arity, then run a primitive or enter a closure's
-- body (whose tail call is returned, not run).
applyStep :: Value -> [Value] -> IO Step
applyStep f args = case f of
  VPrim p -> do
    let n = length args
    if n < primMin p || maybe False (n >) (primMax p)
      then throwIO ArityError
      else primFn p args
  VClosure c -> do
    env <- bindParams c args
    stepBody (cloBody c) env
  _ -> throwIO TypeError

bindParams :: Closure -> [Value] -> IO Env
bindParams c args = case cloParams c of
  Params req Nothing -> do
    let n = cloArity c
    if length args /= n then throwIO ArityError else newFrame (cloEnv c) (zip req args)
  Params req (Just r) -> do
    let n = cloArity c
    if length args < n
      then throwIO ArityError
      else do
        let (fixed, extra) = splitAt n args
        restList <- fromList extra
        newFrame (cloEnv c) ((r, restList) : zip req fixed)
