-- | Evaluation of one line of the query language (@\<a\> \<op\> \<b\>@).
module Query
  ( evalLine
  , evalAll
  ) where

import qualified Data.ByteString.Char8 as BC

import qualified Data.BigInt as B

-- | Evaluate one query line and return the output line (without newline).
-- A well-formed query whose operation is undefined (division by zero,
-- negative exponent) yields @error@.  Malformed lines also yield @error@.
evalLine :: BC.ByteString -> BC.ByteString
evalLine line = case BC.split ' ' line of
  [sa, op, sb]
    | Just a <- B.parse sa, Just b <- B.parse sb -> maybe err id (apply (BC.unpack op) a b)
  _ -> err
  where
    err = BC.pack "error"

apply :: String -> B.BigInt -> B.BigInt -> Maybe BC.ByteString
apply op a b = case op of
  "+" -> Just (B.render (B.add a b))
  "-" -> Just (B.render (B.sub a b))
  "*" -> Just (B.render (B.mul a b))
  "/" -> B.render <$> B.quot a b
  "%" -> B.render <$> B.rem a b
  "^" -> B.render <$> B.pow a b
  "cmp" -> Just (BC.pack (show (cmpInt (compare a b))))
  _ -> Nothing
  where
    cmpInt o = fromEnum o - 1 :: Int

-- | Evaluate every line of an input text, in order.
evalAll :: BC.ByteString -> [BC.ByteString]
evalAll = map evalLine . BC.lines
