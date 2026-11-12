-- | A lazy, ordered stream of results that may end in an error.
--
-- jq filters produce zero or more outputs and may abort with an error; all
-- outputs produced before the error remain observable.  'Stream' models this
-- directly: it is a lazy list whose terminator is either 'Done' or 'Failed'.
module Jq.Stream
  ( Stream (..)
  , single
  , fromList
  , appendS
  , tryS
  , collectS
  , lastS
  , firstS
  , toEithers
  ) where

infixr 5 :>

-- | A lazy stream of values ending in success ('Done') or an error ('Failed').
data Stream a
  = Done
  | Failed
  | a :> Stream a

instance Functor Stream where
  fmap _ Done = Done
  fmap _ Failed = Failed
  fmap f (x :> r) = f x :> fmap f r

instance Applicative Stream where
  pure = single
  fs <*> xs = fs >>= \f -> fmap f xs

instance Monad Stream where
  Done >>= _ = Done
  Failed >>= _ = Failed
  (x :> r) >>= f = f x `appendS` (r >>= f)

-- | A stream with exactly one output.
single :: a -> Stream a
single x = x :> Done

-- | A successful stream holding the elements of a list.
fromList :: [a] -> Stream a
fromList = foldr (:>) Done

-- | Concatenate two streams.  If the first one fails, the second is never
-- started.
appendS :: Stream a -> Stream a -> Stream a
appendS Done ys = ys
appendS Failed _ = Failed
appendS (x :> r) ys = x :> appendS r ys

-- | @try@: pass outputs through until the first error, then stop silently.
tryS :: Stream a -> Stream a
tryS Failed = Done
tryS Done = Done
tryS (x :> r) = x :> tryS r

-- | All outputs, or 'Nothing' if the stream ends in an error.
collectS :: Stream a -> Maybe [a]
collectS Done = Just []
collectS Failed = Nothing
collectS (x :> r) = (x :) <$> collectS r

-- | The last output (if any); 'Nothing' if the stream ends in an error.
lastS :: Stream a -> Maybe (Maybe a)
lastS = go Nothing
  where
    go acc Done = Just acc
    go _ Failed = Nothing
    go _ (x :> r) = x `seq` go (Just x) r

-- | The first output, evaluated lazily: 'Done' yields @Just Nothing@ and an
-- error before any output yields 'Nothing'.
firstS :: Stream a -> Maybe (Maybe a)
firstS Done = Just Nothing
firstS Failed = Nothing
firstS (x :> _) = Just (Just x)

-- | Convert to a lazy list of 'Right' outputs; a final error becomes one
-- trailing @Left e@.
toEithers :: e -> Stream a -> [Either e a]
toEithers _ Done = []
toEithers e Failed = [Left e]
toEithers e (x :> r) = Right x : toEithers e r
