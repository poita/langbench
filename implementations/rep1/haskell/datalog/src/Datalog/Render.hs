-- |
-- Module      : Datalog.Render
-- Description : Output formatting for query answers.
module Datalog.Render
  ( renderConst
  , renderTuple
  , renderAnswer
  , renderErrorLine
  ) where

import Data.ByteString.Builder (Builder, byteString, char7, intDec, string7)

import Datalog.Syntax

-- | A constant in canonical form (integers in decimal).
renderConst :: Const -> Builder
renderConst (CInt n) = intDec n
renderConst (CSym s) = byteString s

-- | @pred(v1, v2, ...)@
renderTuple :: Atom -> [Const] -> Builder
renderTuple a vs = byteString (atomPred a) <> char7 '(' <> commaSep (map renderConst vs) <> char7 ')'
  where
    commaSep [] = mempty
    commaSep (x : xs) = x <> mconcat [string7 ", " <> y | y <- xs]

-- | The output block for one query: the matching tuples, one per line,
-- followed by @-- N@.
renderAnswer :: Atom -> [[Const]] -> Builder
renderAnswer a rows =
  mconcat [renderTuple a r <> char7 '\n' | r <- rows]
    <> string7 "-- " <> intDec (length rows) <> char7 '\n'

-- | The single line printed for an unsafe or unstratifiable program.
renderErrorLine :: Builder
renderErrorLine = string7 "error\n"
