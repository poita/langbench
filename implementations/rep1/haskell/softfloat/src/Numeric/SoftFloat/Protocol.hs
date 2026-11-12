{-# LANGUAGE BangPatterns #-}
-- |
-- Module      : Numeric.SoftFloat.Protocol
-- Description : The line-oriented text protocol of the command-line tool
--
-- Input lines are @op a b@ (op in add, sub, mul, div) or @sqrt a@, with
-- operands as 8 lowercase hex digits; each produces one line of 8 hex digits.
module Numeric.SoftFloat.Protocol
  ( Op (..)
  , Request (..)
  , parseLine
  , evalRequest
  , processLine
  , processInput
  ) where

import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Lazy as L
import Data.Char (ord)
import Data.Word (Word32)

import Numeric.SoftFloat

-- | Operation names.
data Op = Add | Sub | Mul | Div | Sqrt
  deriving (Eq, Show, Enum, Bounded)

-- | A parsed input line. For 'Sqrt' the second operand is unused (0).
data Request = Request !Op !Word32 !Word32
  deriving (Eq, Show)

-- | Parse one line (without its terminator).
parseLine :: C.ByteString -> Either String Request
parseLine l = case C.split ' ' l of
  [o, x] | o == C.pack "sqrt" -> Request Sqrt <$> hex8 x <*> pure 0
  [o, x, y] -> do
    op <- case C.unpack o of
      "add" -> Right Add
      "sub" -> Right Sub
      "mul" -> Right Mul
      "div" -> Right Div
      _ -> Left ("unknown operation: " ++ C.unpack o)
    Request op <$> hex8 x <*> hex8 y
  _ -> Left ("malformed line: " ++ C.unpack l)

hex8 :: C.ByteString -> Either String Word32
hex8 s
  | C.length s /= 8 = Left ("bad operand: " ++ C.unpack s)
  | otherwise = C.foldl' step (Right 0) s
  where
    step (Left e) _ = Left e
    step (Right !acc) c
      | c >= '0' && c <= '9' = Right (acc * 16 + fromIntegral (ord c - 48))
      | c >= 'a' && c <= 'f' = Right (acc * 16 + fromIntegral (ord c - 87))
      | otherwise = Left ("bad operand: " ++ C.unpack s)

-- | Evaluate a request.
evalRequest :: Request -> Word32
evalRequest (Request op a b) = case op of
  Add -> f32Add a b
  Sub -> f32Sub a b
  Mul -> f32Mul a b
  Div -> f32Div a b
  Sqrt -> f32Sqrt a

-- | Parse and evaluate one line.
processLine :: C.ByteString -> Either String Word32
processLine l = evalRequest <$> parseLine l

-- | Process a whole input (lines separated by @\\n@, a trailing newline
-- optional, a trailing @\\r@ tolerated) into the output text, or the first
-- error found.
processInput :: C.ByteString -> Either String L.ByteString
processInput inp = B.toLazyByteString . mconcat <$> traverse one (C.lines inp)
  where
    one l = (\w -> B.word32HexFixed w <> B.char7 '\n')
              <$> processLine (stripCR l)
    stripCR l | not (C.null l) && C.last l == '\r' = C.init l
              | otherwise = l
