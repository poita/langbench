-- |
-- Module      : Scheme.Analyze
-- Description : One-time translation of datums into evaluable 'Node' trees.
--
-- Every form, including every @lambda@ body, is analysed exactly once before
-- it first runs; the evaluator never looks at raw s-expressions.  Variable
-- references stay symbolic and are resolved by name at run time.
module Scheme.Analyze
  ( analyze
  ) where

import Control.Exception (throwIO)

import Scheme.Types

-- | Translate a datum into code.  Throws 'SyntaxError' on malformed special
-- forms.
analyze :: Value -> IO Node
analyze v = case v of
  VSym s -> pure (Ref s)
  VPair _ (VSym s) rest | symName s `elem` reserved -> special (symName s) rest
  VPair _ f args -> App <$> analyze f <*> (mapM analyze =<< listToHs args)
  VNil -> bad "empty application ()"
  _ -> pure (Const v)

bad :: String -> IO a
bad = throwIO . SyntaxError

listToHs :: Value -> IO [Value]
listToHs VNil = pure []
listToHs (VPair _ a d) = (a :) <$> listToHs d
listToHs _ = bad "improper list in code"

reserved :: [String]
reserved =
  [ "quote", "if", "define", "set!", "lambda", "let", "let*", "letrec"
  , "begin", "cond", "and", "or", "else" ]

special :: String -> Value -> IO Node
special name rest = do
  args <- listToHs rest
  case (name, args) of
    ("quote", [d]) -> pure (Const d)
    ("if", [c, t]) -> If <$> analyze c <*> analyze t <*> pure (Const VVoid)
    ("if", [c, t, e]) -> If <$> analyze c <*> analyze t <*> analyze e
    ("define", [VSym n, e]) -> Define n <$> analyze e
    ("define", VPair _ (VSym n) ps : body@(_ : _)) ->
      Define n <$> (Lambda <$> parseParams ps <*> analyzeBody body)
    ("set!", [VSym n, e]) -> Set n <$> analyze e
    ("lambda", ps : body@(_ : _)) -> Lambda <$> parseParams ps <*> analyzeBody body
    ("let", VSym n : bs : body@(_ : _)) -> do
      bs' <- bindings bs
      b <- analyzeBody body
      pure (NamedLet n bs' (Params (map fst bs') Nothing) b)
    ("let", bs : body@(_ : _)) -> Let <$> bindings bs <*> analyzeBody body
    ("let*", bs : body@(_ : _)) -> LetStar <$> bindings bs <*> analyzeBody body
    ("letrec", bs : body@(_ : _)) -> Letrec <$> bindings bs <*> analyzeBody body
    ("begin", body@(_ : _)) -> Begin <$> analyzeBody body
    ("cond", clauses) -> Cond <$> mapM clause clauses
    ("and", xs) -> And <$> mapM analyze xs
    ("or", xs) -> Or <$> mapM analyze xs
    _ -> bad ("malformed " ++ name)

-- | A non-empty body.
analyzeBody :: [Value] -> IO Body
analyzeBody forms = do
  nodes <- mapM analyze forms
  case reverse nodes of
    [] -> bad "empty body"
    l : revInit -> pure (reverse revInit, l)

-- | @((name init) ...)@
bindings :: Value -> IO [(Symbol, Node)]
bindings bs = listToHs bs >>= mapM one
  where
    one b = do
      parts <- listToHs b
      case parts of
        [VSym n, e] -> (,) n <$> analyze e
        _ -> bad "malformed binding"

-- | @(a b)@, @(a b . rest)@ or @rest@.
parseParams :: Value -> IO Params
parseParams = go []
  where
    go acc VNil = pure (Params (reverse acc) Nothing)
    go acc (VSym r) = pure (Params (reverse acc) (Just r))
    go acc (VPair _ (VSym p) d) = go (p : acc) d
    go _ _ = bad "malformed parameter list"

clause :: Value -> IO Clause
clause c = do
  parts <- listToHs c
  case parts of
    VSym s : body@(_ : _) | symName s == "else" -> Else <$> analyzeBody body
    [t] -> (\t' -> Clause t' Nothing) <$> analyze t
    t : body -> (\t' b -> Clause t' (Just b)) <$> analyze t <*> analyzeBody body
    [] -> bad "empty cond clause"
