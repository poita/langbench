-- |
-- Module      : Scheme.Interpreter
-- Description : Running whole programs: read, analyse, evaluate, print.
module Scheme.Interpreter
  ( Interpreter
  , newInterpreter
  , evalSource
  , evalSourceWith
  , runProgram
  , runProgramToString
  ) where

import Control.Exception (try)
import Data.IORef

import Scheme.Analyze (analyze)
import Scheme.Eval (eval)
import Scheme.Primitives (primitives)
import Scheme.Printer (writeString)
import Scheme.Reader (readDatum)
import Scheme.Types

-- | An interpreter session: a symbol table, a global environment and an
-- output sink.  Definitions persist across calls to 'evalSource'.
data Interpreter = Interpreter
  { itSymbols :: SymbolTable
  , itGlobal  :: Env
  }

-- | Create an interpreter whose @display@ and @newline@ write through the
-- given function.  The global environment holds exactly the primitives.
newInterpreter :: (String -> IO ()) -> IO Interpreter
newInterpreter out = do
  tbl <- newSymbolTable
  global <- newGlobalEnv
  mapM_
    (\p -> do s <- intern tbl (primName p); defineVar s (VPrim p) global)
    (primitives out)
  pure (Interpreter tbl global)

-- | Evaluate the forms of a program in order, passing the value of each to
-- the callback (void values included).  Stops at the first error.
evalSourceWith :: Interpreter -> (Value -> IO ()) -> String -> IO (Either SchemeError ())
evalSourceWith it onValue = try . loop
  where
    loop src = do
      next <- readDatum (itSymbols it) src
      case next of
        Nothing -> pure ()
        Just (d, rest) -> do
          node <- analyze d
          v <- eval node (itGlobal it)
          onValue v
          loop rest

-- | Evaluate a program and collect the values of its forms.
evalSource :: Interpreter -> String -> IO (Either SchemeError [Value])
evalSource it src = do
  acc <- newIORef []
  r <- evalSourceWith it (\v -> modifyIORef acc (v :)) src
  vs <- reverse <$> readIORef acc
  pure (vs <$ r)

-- | Run a program with the command-line tool's semantics: every non-void
-- top-level value is written on its own line, and a runtime error appends
-- @error: <category>@ and stops.  All text goes through the given sink.
runProgram :: (String -> IO ()) -> String -> IO ()
runProgram out src = do
  it <- newInterpreter out
  r <- evalSourceWith it printValue src
  case r of
    Left e -> out ("error: " ++ errorCategory e ++ "\n")
    Right () -> pure ()
  where
    printValue VVoid = pure ()
    printValue v = out (writeString v ++ "\n")

-- | 'runProgram' collecting the output into a string.
runProgramToString :: String -> IO String
runProgramToString src = do
  acc <- newIORef []
  runProgram (\s -> modifyIORef' acc (s :)) src
  concat . reverse <$> readIORef acc
