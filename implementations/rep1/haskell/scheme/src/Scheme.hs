-- |
-- Module      : Scheme
-- Description : A small Scheme interpreter: public API.
--
-- >>> import Scheme
-- >>> runProgramToString "(define (sq x) (* x x)) (sq 12) (display \"hi\")"
-- "144\nhi"
--
-- The pipeline is: "Scheme.Reader" (text to datums), "Scheme.Analyze"
-- (datums to 'Scheme.Types.Node' trees, once per form), "Scheme.Eval"
-- (trampolined evaluation), "Scheme.Printer" (values to text).  Integers
-- are arbitrary precision ("Scheme.BigInt").
module Scheme
  ( -- * Running programs
    runProgram
  , runProgramToString
    -- * Sessions
  , Interpreter
  , newInterpreter
  , evalSource
  , evalSourceWith
    -- * Values and errors
  , Value (..)
  , SchemeError (..)
  , errorCategory
  , writeString
  , displayString
  ) where

import Scheme.Interpreter
import Scheme.Printer (displayString, writeString)
import Scheme.Types (SchemeError (..), Value (..), errorCategory)
