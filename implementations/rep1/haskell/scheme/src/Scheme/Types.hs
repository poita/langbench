-- |
-- Module      : Scheme.Types
-- Description : Core data types shared by the reader, analyser and evaluator.
module Scheme.Types
  ( -- * Symbols
    Symbol (..)
  , SymbolTable
  , newSymbolTable
  , intern
    -- * Values
  , Value (..)
  , Token
  , Closure (..)
  , Params (..)
  , Prim (..)
  , Step (..)
  , cons
  , fromList
  , isTrue
    -- * Syntax tree
  , Node (..)
  , Body
  , Clause (..)
    -- * Environments
  , Env (..)
  , newGlobalEnv
  , newFrame
  , defineVar
  , lookupVar
  , assignVar
    -- * Errors
  , SchemeError (..)
  , errorCategory
  ) where

import Control.Exception (Exception, throwIO)
import Data.IORef
import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict as M

import Scheme.BigInt (BigInt)

------------------------------------------------------------------------
-- Symbols

-- | An interned symbol.  Two symbols with the same name obtained from the
-- same 'SymbolTable' have the same 'symId'.
data Symbol = Symbol
  { symId   :: !Int
  , symName :: String
  }

instance Eq Symbol where
  a == b = symId a == symId b

instance Show Symbol where
  show = symName

-- | The interning table.
newtype SymbolTable = SymbolTable (IORef (M.Map String Symbol))

-- | A fresh, empty symbol table.
newSymbolTable :: IO SymbolTable
newSymbolTable = SymbolTable <$> newIORef M.empty

-- | Intern a name: the same name always yields the same 'Symbol'.
intern :: SymbolTable -> String -> IO Symbol
intern (SymbolTable ref) name = do
  m <- readIORef ref
  case M.lookup name m of
    Just s -> pure s
    Nothing -> do
      let s = Symbol (M.size m) name
      writeIORef ref (M.insert name s m)
      pure s

------------------------------------------------------------------------
-- Values

-- | Object identity for pairs and closures, so that @eq?@ can tell two
-- structurally equal but separately allocated objects apart.
type Token = IORef ()

-- | A Scheme value.
data Value
  = VInt !BigInt
  | VBool !Bool
  | VStr String
  | VSym !Symbol
  | VPair !Token Value Value
  | VNil
  | VVoid
  | VClosure !Closure
  | VPrim !Prim

-- | Formal parameters of a lambda: required symbols and an optional rest symbol.
data Params = Params [Symbol] (Maybe Symbol)

-- | A user-defined procedure.
data Closure = Closure
  { cloToken  :: !Token
  , cloParams :: !Params
  , cloArity  :: !Int          -- ^ number of required parameters
  , cloBody   :: Body
  , cloEnv    :: Env
  }

-- | A primitive procedure.  Arity is checked by the evaluator before
-- 'primFn' runs.
data Prim = Prim
  { primName :: String
  , primMin  :: !Int
  , primMax  :: Maybe Int      -- ^ 'Nothing' for variadic
  , primFn   :: [Value] -> IO Step
  }

-- | The result of one evaluation step: a value, or a pending call that the
-- trampoline will perform.
data Step
  = Done Value
  | TailCall Value [Value]

-- | Allocate a pair with a fresh identity.
cons :: Value -> Value -> IO Value
cons a d = do
  t <- newIORef ()
  pure (VPair t a d)

-- | Build a proper list.
fromList :: [Value] -> IO Value
fromList = go
  where
    go [] = pure VNil
    go (x : xs) = go xs >>= cons x

-- | Only @#f@ is false.
isTrue :: Value -> Bool
isTrue (VBool False) = False
isTrue _ = True

------------------------------------------------------------------------
-- Syntax tree

-- | Analysed code.  Produced once per form by "Scheme.Analyze" and run by
-- "Scheme.Eval".
data Node
  = Const Value
  | Ref Symbol
  | Set Symbol Node
  | Define Symbol Node
  | If Node Node Node
  | Lambda Params Body
  | Let [(Symbol, Node)] Body
  | NamedLet Symbol [(Symbol, Node)] Params Body
  | LetStar [(Symbol, Node)] Body
  | Letrec [(Symbol, Node)] Body
  | Begin Body
  | Cond [Clause]
  | And [Node]
  | Or [Node]
  | App Node [Node]

-- | A non-empty sequence of forms: the leading forms and the final one
-- (which is in tail position).
type Body = ([Node], Node)

-- | A @cond@ clause.
data Clause
  = Clause Node (Maybe Body)   -- ^ @(test body...)@ or @(test)@
  | Else Body                  -- ^ @(else body...)@

------------------------------------------------------------------------
-- Environments

-- | A chain of frames.  Each frame maps symbol ids to values; the outermost
-- frame is the global environment.
data Env = Env
  { envFrame  :: !(IORef (IM.IntMap Value))
  , envParent :: Maybe Env
  }

-- | A new, empty global environment.
newGlobalEnv :: IO Env
newGlobalEnv = do
  r <- newIORef IM.empty
  pure (Env r Nothing)

-- | A new frame below the given environment, holding the given bindings.
newFrame :: Env -> [(Symbol, Value)] -> IO Env
newFrame parent bs = do
  r <- newIORef (IM.fromList [(symId s, v) | (s, v) <- bs])
  pure (Env r (Just parent))
{-# INLINE newFrame #-}

-- | Bind (or rebind) a name in the innermost frame.
defineVar :: Symbol -> Value -> Env -> IO ()
defineVar s v env = modifyIORef' (envFrame env) (IM.insert (symId s) v)

-- | Look a name up, innermost frame first.
lookupVar :: Symbol -> Env -> IO Value
lookupVar s = go
  where
    k = symId s
    go env = do
      m <- readIORef (envFrame env)
      case IM.lookup k m of
        Just v -> pure v
        Nothing -> maybe (throwIO UnboundVariable) go (envParent env)

-- | Assign to the nearest existing binding of a name.
assignVar :: Symbol -> Value -> Env -> IO ()
assignVar s v = go
  where
    k = symId s
    go env = do
      m <- readIORef (envFrame env)
      if IM.member k m
        then writeIORef (envFrame env) (IM.insert k v m)
        else maybe (throwIO UnboundVariable) go (envParent env)

------------------------------------------------------------------------
-- Errors

-- | The runtime errors of the language, plus syntax errors for malformed
-- programs.
data SchemeError
  = UnboundVariable
  | TypeError
  | ArityError
  | DivisionByZero
  | UserError
  | SyntaxError String
  deriving (Eq, Show)

instance Exception SchemeError

-- | The category name printed after @error: @.
errorCategory :: SchemeError -> String
errorCategory e = case e of
  UnboundVariable -> "unbound-variable"
  TypeError -> "type-error"
  ArityError -> "arity-error"
  DivisionByZero -> "division-by-zero"
  UserError -> "user-error"
  SyntaxError _ -> "syntax-error"
