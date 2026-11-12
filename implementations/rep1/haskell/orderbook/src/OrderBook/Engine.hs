{-# LANGUAGE BangPatterns #-}
-- |
-- Module      : OrderBook.Engine
-- Description : Price-time-priority matching on top of "OrderBook.Book".
module OrderBook.Engine
  ( execute
  , run
  , runFrom
  ) where

import qualified OrderBook.Book as B
import OrderBook.Book (Book)
import OrderBook.Types

-- | Execute one command, returning the events it produces (at least one,
-- in output order) and the new book.
execute :: Command -> Book -> ([Event], Book)
execute cmd book = case cmd of
  Limit oid side price qty tif -> limitOrder oid side price qty tif book
  Market oid side qty ->
    let (evs, rest, b') = match oid side Nothing qty book
    in (evs ++ [final oid rest], b')
    where final i 0 = Filled i
          final i r = Cancelled i r
  Cancel oid -> case B.removeOrder oid book of
    Nothing           -> ([Reject oid], book)
    Just (_, rest, b) -> ([Cancelled oid rest], b)
  Replace oid price qty -> case B.lookupOrder oid book of
    Nothing -> ([Reject oid], book)
    Just (r, e)
      | B.restingPrice r == price && qty <= B.entryQty e ->
          ([Rest oid], B.reduceOrder oid qty book)
      | otherwise -> case B.removeOrder oid book of
          Nothing -> ([Reject oid], book)  -- unreachable
          Just (_, _, b0) ->
            limitOrder oid (B.restingSide r) price qty GoodTillCancel b0
  Snapshot ->
    let (bids, asks) = B.snapshot book
    in ( [BidLevel p q n | (p, q, n) <- bids]
         ++ [AskLevel p q n | (p, q, n) <- asks]
         ++ [EndOfBook]
       , book )

limitOrder :: OrderId -> Side -> Price -> Qty -> TimeInForce -> Book
           -> ([Event], Book)
limitOrder oid side price qty tif book = case tif of
  FillOrKill
    | available < qty -> ([Reject oid], book)
  _ ->
    let (evs, rest, b') = match oid side (Just price) qty book
    in if rest == 0
         then (evs ++ [Filled oid], b')
         else case tif of
           GoodTillCancel -> (evs ++ [Rest oid], B.insertOrder side price oid rest b')
           _              -> (evs ++ [Cancelled oid rest], b')
  where
    available = sum (map (B.levelTotal . snd)
                  (takeWhile (crosses side price . fst)
                             (B.levelsFrom (opposite side) book)))

-- | Does a taker on @side@ with limit @price@ cross a resting price @q@?
crosses :: Side -> Price -> Price -> Bool
crosses Buy  p q = q <= p
crosses Sell p q = q >= p

-- | Match a taker against the opposite side. Returns trade events (with
-- maker @Filled@ lines), the taker's remaining quantity and the new book.
match :: OrderId -> Side -> Maybe Price -> Qty -> Book -> ([Event], Qty, Book)
match taker side limit = go id
  where
    opp = opposite side
    ok q = maybe True (\p -> crosses side p q) limit
    go acc !remaining !b
      | remaining == 0 = (acc [], 0, b)
      | otherwise = case B.bestLevel opp b of
          Just (price, lvl)
            | ok price
            , Just e <- B.frontEntry lvl ->
                let t = min remaining (B.entryQty e)
                    left = B.entryQty e - t
                    evs = Trade taker (B.entryId e) price t
                          : [Filled (B.entryId e) | left == 0]
                in go (acc . (evs ++)) (remaining - t) (B.popFront opp price left b)
          _ -> (acc [], remaining, b)

-- | Run a whole command stream from the empty book, lazily producing events.
run :: [Command] -> [Event]
run = runFrom B.empty

-- | Like 'run' but starting from a given book.
runFrom :: Book -> [Command] -> [Event]
runFrom _ [] = []
runFrom b (c : cs) = case execute c b of
  (evs, !b') -> evs ++ runFrom b' cs
