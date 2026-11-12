-- | Lazy, ordered result streams that can end in an error.
--
-- A 'Stream' yields values one at a time; an error terminates it, but every
-- value produced before the error is still observable. All combinators are
-- lazy in the tail.
module Jq.Stream
  ( Stream (..)
  , single
  , failS
  , fromList
  , append
  , bindS
  , mapS
  , tryS
  , collect
  , lastS
  , toResults
  ) where

import Data.Text (Text)

import Jq.Value

data Stream
  = Nil
  | Cons Value Stream
  | Err Text      -- ^ evaluation aborted with this message

single :: Value -> Stream
single v = Cons v Nil

failS :: Text -> Stream
failS = Err

fromList :: [Value] -> Stream
fromList = foldr Cons Nil

-- | Concatenate; an error in the first stream hides the second.
append :: Stream -> Stream -> Stream
append Nil t = t
append (Cons v s) t = Cons v (append s t)
append e@(Err _) _ = e

-- | For each output of the first stream (in order), all outputs of @f@.
bindS :: Stream -> (Value -> Stream) -> Stream
bindS Nil _ = Nil
bindS (Err m) _ = Err m
bindS (Cons v s) f = f v `append` bindS s f

mapS :: (Value -> Value) -> Stream -> Stream
mapS _ Nil = Nil
mapS _ (Err m) = Err m
mapS f (Cons v s) = Cons (f v) (mapS f s)

-- | @try@: stop at the first error and swallow it.
tryS :: Stream -> Stream
tryS (Cons v s) = Cons v (tryS s)
tryS _ = Nil

-- | Force a whole stream into a list; fails with the first error.
collect :: Stream -> Either Text [Value]
collect = go []
  where
    go acc Nil = Right (reverse acc)
    go _ (Err m) = Left m
    go acc (Cons v s) = go (v : acc) s

-- | The last output (if any); fails if the stream errors at any point.
lastS :: Stream -> Either Text (Maybe Value)
lastS = go Nothing
  where
    go l Nil = Right l
    go _ (Err m) = Left m
    go _ (Cons v s) = go (Just v) s

-- | The outputs produced before the stream ended, and the error that ended
-- it, if any.
toResults :: Stream -> ([Value], Maybe Text)
toResults Nil = ([], Nothing)
toResults (Err m) = ([], Just m)
toResults (Cons v s) = let (vs, e) = toResults s in (v : vs, e)
