-- | langvm: a compiler and stack virtual machine for the Vellum language.
--
-- The pipeline is: split the input into modules ("Langvm.Source"), lex
-- ("Langvm.Lexer"), parse ("Langvm.Parser"), resolve items and names
-- ("Langvm.Items"), type-check ("Langvm.Check"), compile to bytecode
-- ("Langvm.Compile") and run ("Langvm.VM").
module Langvm
  ( -- * Running programs
    runSource
  , Outcome (..)
  , executeText
    -- * The phases
  , compile
  , compileText
  , Program
  , run
    -- * Diagnostics
  , Diagnostic (..)
  , Kind (..)
  , Pos (..)
  , renderDiagnostic
  ) where

import Data.IORef (modifyIORef', newIORef, readIORef)

import Langvm.Bytecode (Program)
import Langvm.Builtin (preludeSource)
import Langvm.Check (checkProgram)
import Langvm.Compile (compileProgram)
import Langvm.Diagnostic
import Langvm.Items (buildGlobals)
import Langvm.Lexer (lexModule)
import Langvm.Parser (parseModule)
import Langvm.Source
import Langvm.Syntax (Module)
import Langvm.Value (strToString)
import Langvm.VM (runProgram)

-- | How a program that compiled finished.
data Outcome
  = Finished              -- ^ @main@ returned
  | Panicked String       -- ^ a runtime error, with its message
  deriving (Eq, Show)

-- | Compile a module stream (the whole of stdin) to bytecode.
compileText :: String -> Either Diagnostic Program
compileText input = do
  srcMods <- splitModules input
  toks <- mapM (\m -> (,) m <$> lexModule (smLines m)) srcMods
  mods <- mapM (\(m, ts) -> parseModule (smName m) (eofPos m) ts) toks
  prelude <- preludeModule
  compile (prelude : mods)
  where
    eofPos m = case smLines m of
      [] -> Pos 1 1
      ls -> Pos (length ls) (length (last ls) + 1)

preludeModule :: Either Diagnostic Module
preludeModule = do
  toks <- lexModule preludeSource
  parseModule "" (Pos 1 1) toks

-- | Compile parsed modules; the first must be the prelude.
compile :: [Module] -> Either Diagnostic Program
compile mods = do
  (g, recs) <- buildGlobals mods
  checked <- checkProgram g recs
  return (compileProgram g checked)

-- | Run a compiled program, sending its output to the callback.
run :: Program -> (String -> IO ()) -> IO Outcome
run prog out = maybe Finished Panicked <$> runProgram prog (out . strToString)

-- | Compile and run a module stream, sending the program's output to the
-- callback.  A compile error is returned as 'Left' and nothing is output.
runSource :: String -> (String -> IO ()) -> IO (Either Diagnostic Outcome)
runSource input out = case compileText input of
  Left d -> return (Left d)
  Right prog -> Right <$> run prog out

-- | Everything the command-line tool writes to stdout for an input: the
-- program's output, or the single diagnostic line, or the output followed by
-- the panic line.
executeText :: String -> IO String
executeText input = do
  acc <- newIORef []
  result <- runSource input (\s -> modifyIORef' acc (s :))
  out <- concat . reverse <$> readIORef acc
  return $ case result of
    Left d -> renderDiagnostic d ++ "\n"
    Right Finished -> out
    Right (Panicked msg) -> out ++ "panic: " ++ msg ++ "\n"
