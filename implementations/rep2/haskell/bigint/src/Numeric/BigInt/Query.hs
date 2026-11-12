{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : Numeric.BigInt.Query
-- Description : Line-oriented query evaluator used by the command-line tool.
--
-- Each query is a line @\<a\> \<op\> \<b\>@ where @op@ is one of
-- @+ - * / % ^ cmp@.  The reply is the canonical decimal result, @-1@\/@0@\/@1@
-- for @cmp@, or @error@ for division by zero and negative exponents.
module Numeric.BigInt.Query
  ( evalQuery
  , evalInput
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Numeric.BigInt

-- | Evaluate one query line.  Returns 'Nothing' when the line is not a
-- well-formed query; @Just "error"@ for the defined error cases.
evalQuery :: B.ByteString -> Maybe B.ByteString
evalQuery line = case BC.split ' ' line of
  [sa, op, sb] -> do
    a <- parseBigInt sa
    b <- parseBigInt sb
    run op a b
  _ -> Nothing
  where
    ok = Just . renderBigInt
    orErr = Just . maybe "error" renderBigInt
    run "+" a b = ok (addBig a b)
    run "-" a b = ok (subBig a b)
    run "*" a b = ok (mulBig a b)
    run "/" a b = orErr (fst <$> quotRemBig a b)
    run "%" a b = orErr (snd <$> quotRemBig a b)
    run "^" a b = orErr (powBig a b)
    run "cmp" a b = Just $ case compare a b of
      LT -> "-1"
      EQ -> "0"
      GT -> "1"
    run _ _ _ = Nothing

-- | Evaluate a whole input: one output line (newline-terminated) per
-- non-empty input line.  Lines that are not well-formed queries produce
-- @error@ so that output stays aligned with input.
evalInput :: B.ByteString -> B.ByteString
evalInput = B.concat . concatMap reply . BC.lines
  where
    reply l | B.null l = []
            | otherwise = [maybe "error" id (evalQuery l), "\n"]
