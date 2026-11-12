-- | Hindley-Milner type inference for a small ML-like language.
--
-- The language has integers, booleans, unit, tuples, lists, first-class
-- functions, @let@ / @let rec@ with full let-polymorphism (no value
-- restriction) and a handful of built-ins. See the README for the grammar.
--
-- > import Language.TypeInfer
-- >
-- > main :: IO ()
-- > main = case inferSource "let compose f g x = f (g x);;" of
-- >   Left err  -> putStrLn (renderParseError err)
-- >   Right rs  -> mapM_ (putStrLn . renderResult) rs
-- > -- compose : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b
module Language.TypeInfer
  ( -- * Running inference
    inferSource
  , inferProgram
  , inferExpr
  , DeclResult (..)
  , renderResult
    -- * Parsing
  , parseProgram
  , parseExpr
    -- * Types and errors
  , Type (..)
  , renderType
  , varName
  , freeVars
  , TypeError (..)
  , errorKind
  , ParseError (..)
  , Pos (..)
  , renderParseError
    -- * Syntax
  , module Language.TypeInfer.Syntax
    -- * Built-ins
  , builtinTypes
  ) where

import Language.TypeInfer.Builtins
import Language.TypeInfer.Error
import Language.TypeInfer.Infer
import Language.TypeInfer.Parser
import Language.TypeInfer.Syntax
import Language.TypeInfer.Type

-- | Parse a program and infer the type of each declaration.
inferSource :: String -> Either ParseError [DeclResult]
inferSource = fmap inferProgram . parseProgram

-- | One line of CLI output for a declaration: @name : type@, @- : type@ or
-- @error: kind@.
renderResult :: DeclResult -> String
renderResult (DeclResult name outcome) = case outcome of
  Left err -> "error: " ++ errorKind err
  Right ty -> maybe "-" id name ++ " : " ++ renderType ty
