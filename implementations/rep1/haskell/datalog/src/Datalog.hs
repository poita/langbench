-- |
-- Module      : Datalog
-- Description : A Datalog engine with stratified negation.
--
-- Typical use:
--
-- > import qualified Data.ByteString.Char8 as B
-- > import Datalog
-- >
-- > main :: IO ()
-- > main = do
-- >   let src = B.pack "edge(1,2). edge(2,3). path(X,Y) :- edge(X,Y). \
-- >                    \path(X,Z) :- edge(X,Y), path(Y,Z). ?- path(1,X)."
-- >   case parseProgram src of
-- >     Left err    -> print err
-- >     Right prog  -> case evaluate prog of
-- >       Left e      -> putStrLn ("rejected: " ++ show e)
-- >       Right model -> print (queryModel model (Atom (B.pack "path") [TConst (CInt 1), TVar (B.pack "X")]))
--
-- 'runProgram' and 'runSource' do the whole job and produce the exact text
-- of the command-line tool.
module Datalog
  ( -- * Syntax
    module Datalog.Syntax
    -- * Parsing
  , ParseError (..)
  , parseProgram
    -- * Static checks
  , Error (..)
  , isSafe
  , checkSafety
  , Component (..)
  , stratify
    -- * Evaluation
  , Model
  , evaluate
  , queryModel
  , relationTuples
    -- * Running whole programs
  , runProgram
  , runSource
  ) where

import Data.ByteString (ByteString)
import Data.ByteString.Builder (Builder)

import Datalog.Analysis
import Datalog.Eval
import Datalog.Parser
import Datalog.Render
import Datalog.Syntax

-- | Evaluate a program and answer all its queries in source order. The
-- result is the exact output of the command-line tool: for every query the
-- matching tuples followed by @-- N@, or the single line @error@ when the
-- program is unsafe or not stratifiable.
runProgram :: Program -> Builder
runProgram prog = case evaluate prog of
  Left _ -> renderErrorLine
  Right model -> mconcat [renderAnswer q (queryModel model q) | q <- clauseQueries prog]

-- | Parse and run program text.
runSource :: ByteString -> Either ParseError Builder
runSource src = runProgram <$> parseProgram src
