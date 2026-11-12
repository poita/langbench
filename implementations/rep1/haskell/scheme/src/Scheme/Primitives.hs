-- |
-- Module      : Scheme.Primitives
-- Description : The built-in procedures of the language.
module Scheme.Primitives
  ( primitives
  , eqP
  , equalP
  ) where

import Control.Exception (throwIO)

import qualified Scheme.BigInt as B
import Scheme.Printer (displayString)
import Scheme.Types

-- | All primitives, given the sink that @display@ and @newline@ write to.
primitives :: (String -> IO ()) -> [Prim]
primitives out =
  [ -- arithmetic
    pureP "+" 0 Nothing (fmap (VInt . foldl B.add (B.fromInt 0)) . ints)
  , pureP "*" 0 Nothing (fmap (VInt . foldl B.mul (B.fromInt 1)) . ints)
  , pureP "-" 1 Nothing $ \args -> do
      ns <- ints args
      pure . VInt $ case ns of
        [x] -> B.neg x
        x : xs -> foldl B.sub x xs
        [] -> B.fromInt 0
  , pureP "quotient" 2 (Just 2) (divide B.quot)
  , pureP "remainder" 2 (Just 2) (divide B.rem)
  , compareP "=" (==)
  , compareP "<" (<)
  , compareP ">" (>)
  , compareP "<=" (<=)
  , compareP ">=" (>=)
    -- pairs and lists
  , binaryP "cons" $ \a d -> cons a d
  , unaryP "car" $ \p -> case p of
      VPair _ a _ -> pure a
      _ -> throwIO TypeError
  , unaryP "cdr" $ \p -> case p of
      VPair _ _ d -> pure d
      _ -> throwIO TypeError
  , pureP "list" 0 Nothing fromList
  , predP "null?" (\v -> case v of VNil -> True; _ -> False)
  , predP "pair?" (\v -> case v of VPair {} -> True; _ -> False)
    -- predicates and equivalence
  , predP "not" (\v -> case v of VBool False -> True; _ -> False)
  , predP "number?" (\v -> case v of VInt _ -> True; _ -> False)
  , predP "boolean?" (\v -> case v of VBool _ -> True; _ -> False)
  , predP "string?" (\v -> case v of VStr _ -> True; _ -> False)
  , predP "symbol?" (\v -> case v of VSym _ -> True; _ -> False)
  , predP "procedure?" (\v -> case v of VClosure _ -> True; VPrim _ -> True; _ -> False)
  , binaryP "eq?" $ \a b -> pure (VBool (eqP a b))
  , binaryP "equal?" $ \a b -> pure (VBool (equalP a b))
    -- control
  , Prim "apply" 2 Nothing $ \args -> case args of
      f : rest@(_ : _) -> do
        extra <- properList (last rest)
        pure (TailCall f (init rest ++ extra))
      _ -> throwIO ArityError
  , pureP "error" 0 Nothing (const (throwIO UserError))
    -- strings and symbols
  , pureP "string-append" 0 Nothing $ \args -> VStr . concat <$> mapM str args
  , unaryP "string-length" $ \s -> VInt . B.fromInt . length <$> str s
  , unaryP "number->string" $ \n -> VStr . B.toDecimal <$> int n
  , unaryP "symbol->string" $ \s -> case s of
      VSym y -> pure (VStr (symName y))
      _ -> throwIO TypeError
    -- output
  , unaryP "display" $ \v -> out (displayString v) >> pure VVoid
  , pureP "newline" 0 (Just 0) $ \_ -> out "\n" >> pure VVoid
  ]

-- | A primitive whose result is an ordinary value.
pureP :: String -> Int -> Maybe Int -> ([Value] -> IO Value) -> Prim
pureP name lo hi f = Prim name lo hi (fmap Done . f)

unaryP :: String -> (Value -> IO Value) -> Prim
unaryP name f = Prim name 1 (Just 1) $ \args -> case args of
  [a] -> Done <$> f a
  _ -> throwIO ArityError

binaryP :: String -> (Value -> Value -> IO Value) -> Prim
binaryP name f = Prim name 2 (Just 2) $ \args -> case args of
  [a, b] -> Done <$> f a b
  _ -> throwIO ArityError

predP :: String -> (Value -> Bool) -> Prim
predP name p = unaryP name (pure . VBool . p)

-- | A chained integer comparison: all arguments are type-checked first.
compareP :: String -> (B.BigInt -> B.BigInt -> Bool) -> Prim
compareP name rel = pureP name 2 Nothing $ \args -> do
  ns <- ints args
  pure (VBool (and (zipWith rel ns (drop 1 ns))))

divide :: (B.BigInt -> B.BigInt -> Maybe B.BigInt) -> [Value] -> IO Value
divide f [a, b] = do
  x <- int a
  y <- int b
  maybe (throwIO DivisionByZero) (pure . VInt) (f x y)
divide _ _ = throwIO ArityError

int :: Value -> IO B.BigInt
int (VInt n) = pure n
int _ = throwIO TypeError

ints :: [Value] -> IO [B.BigInt]
ints = mapM int

str :: Value -> IO String
str (VStr s) = pure s
str _ = throwIO TypeError

-- | The elements of a proper list, or a type error.
properList :: Value -> IO [Value]
properList VNil = pure []
properList (VPair _ a d) = (a :) <$> properList d
properList _ = throwIO TypeError

-- | @eq?@: numeric equality for integers, identity otherwise.
eqP :: Value -> Value -> Bool
eqP a b = case (a, b) of
  (VInt x, VInt y) -> x == y
  (VBool x, VBool y) -> x == y
  (VSym x, VSym y) -> x == y
  (VNil, VNil) -> True
  (VVoid, VVoid) -> True
  (VPair s _ _, VPair t _ _) -> s == t
  (VClosure x, VClosure y) -> cloToken x == cloToken y
  (VPrim x, VPrim y) -> primName x == primName y
  (VStr x, VStr y) -> x == y -- unspecified by the language; compare contents
  _ -> False

-- | @equal?@: structural on pairs and strings, @eq?@ otherwise.
equalP :: Value -> Value -> Bool
equalP a b = case (a, b) of
  (VPair _ a1 d1, VPair _ a2 d2) -> equalP a1 a2 && equalP d1 d2
  _ -> eqP a b
