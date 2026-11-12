-- |
-- Module      : Datalog
-- Description : A Datalog engine with stratified negation.
--
-- The pipeline is: 'parseProgram' → 'check' (safety, then stratification)
-- → 'evaluate' (semi-naive, per stratum) → 'queryModel'. 'runProgram'
-- does all of it for a source string, and 'renderResults' prints answers
-- in the command-line format.
--
-- @
-- >>> putStr (either (const "error\\n") renderResults (runProgram src))
-- @
module Datalog
  ( -- * One-call interface
    runProgram
  , renderResults
  , QueryResult (..)
  , Error (..)
    -- * Pipeline stages
  , solve
  , parseProgram
  , check
  , evaluate
  , queryModel
  , modelTuples
    -- * Types
  , module Datalog.Syntax
  , Model
  , AnalysisError (..)
  ) where

import Datalog.Analysis
import Datalog.Eval
import Datalog.Model
import Datalog.Parser
import Datalog.Syntax

-- | Anything that can stop a run.
data Error
  = ParseError String
  | Rejected AnalysisError   -- ^ unsafe or not stratifiable
  deriving (Eq, Show)

-- | The answer to one query: the query itself and its sorted matches.
data QueryResult = QueryResult
  { qrQuery  :: Atom
  , qrTuples :: [[Const]]
  } deriving (Eq, Show)

-- | Check a parsed program and compute its perfect model.
solve :: Program -> Either AnalysisError Model
solve p = evaluate p <$> check p

-- | Parse, check and evaluate a program, answering its queries in order.
runProgram :: String -> Either Error [QueryResult]
runProgram src = do
  p <- either (Left . ParseError) Right (parseProgram src)
  m <- either (Left . Rejected) Right (solve p)
  pure [QueryResult q (queryModel m q) | q <- progQueries p]

-- | Render answers: each matching tuple on its own line, then @-- N@.
renderResults :: [QueryResult] -> String
renderResults = concatMap one
  where
    one (QueryResult q ts) =
      unlines (map (renderAtom (atomName q)) ts ++ ["-- " ++ show (length ts)])
