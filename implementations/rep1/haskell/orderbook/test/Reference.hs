-- | A deliberately naive list-based model of the order book, used as an
-- oracle in the property tests. It follows SPEC.md literally and shares no
-- code with the real implementation.
module Reference (refRun) where

import Data.List (sortBy, partition)
import Data.Ord (comparing)

import OrderBook.Types

data R = R { rId :: OrderId, rSide :: Side, rPrice :: Price, rQty :: Qty }

-- | Run a command stream; resting orders are kept in arrival order, so list
-- position is queue position.
refRun :: [Command] -> [Event]
refRun = go []
  where
    go _ [] = []
    go book (c : cs) = let (evs, book') = step book c in evs ++ go book' cs

step :: [R] -> Command -> ([Event], [R])
step book cmd = case cmd of
  Limit i s p q tif -> limit book i s p q tif
  Market i s q ->
    let (evs, rest, b) = match book i s Nothing q
    in (evs ++ [if rest == 0 then Filled i else Cancelled i rest], b)
  Cancel i -> case partition ((== i) . rId) book of
    ([r], b) -> ([Cancelled i (rQty r)], b)
    _        -> ([Reject i], book)
  Replace i p q -> case partition ((== i) . rId) book of
    ([r], _)
      | p == rPrice r && q <= rQty r ->
          ([Rest i], [ if rId x == i then x { rQty = q } else x | x <- book ])
      | otherwise ->
          limit (filter ((/= i) . rId) book) i (rSide r) p q GoodTillCancel
    _ -> ([Reject i], book)
  Snapshot ->
    ( [ BidLevel p (sum qs) (length qs) | (p, qs) <- levels Buy ]
      ++ [ AskLevel p (sum qs) (length qs) | (p, qs) <- levels Sell ]
      ++ [EndOfBook]
    , book )
  where
    prices s = sortBy (if s == Buy then flip compare else compare)
                 (uniq [ rPrice r | r <- book, rSide r == s ])
    uniq [] = []
    uniq (x : xs) = x : uniq (filter (/= x) xs)
    levels s = [ (p, [ rQty r | r <- book, rSide r == s, rPrice r == p ])
               | p <- prices s ]

cross :: Side -> Maybe Price -> Price -> Bool
cross _ Nothing _ = True
cross Buy (Just p) q = q <= p
cross Sell (Just p) q = q >= p

limit :: [R] -> OrderId -> Side -> Price -> Qty -> TimeInForce -> ([Event], [R])
limit book i s p q tif
  | tif == FillOrKill && avail < q = ([Reject i], book)
  | rest == 0 = (evs ++ [Filled i], b)
  | tif == GoodTillCancel = (evs ++ [Rest i], b ++ [R i s p rest])
  | otherwise = (evs ++ [Cancelled i rest], b)
  where
    (evs, rest, b) = match book i s (Just p) q
    avail = sum [ rQty r | r <- book, rSide r /= s, cross s (Just p) (rPrice r) ]

match :: [R] -> OrderId -> Side -> Maybe Price -> Qty -> ([Event], Qty, [R])
match book i s lim q
  | q == 0 || null cands = ([], q, book)
  | otherwise =
      let m = head (sortBy (comparing key) cands)  -- stable: earliest first
          t = min q (rQty m)
          m' = m { rQty = rQty m - t }
          book' = [ if rId x == rId m then m' else x | x <- book ]
          book'' = if rQty m' == 0 then filter ((/= rId m) . rId) book' else book'
          evs = Trade i (rId m) (rPrice m) t : [ Filled (rId m) | rQty m' == 0 ]
          (more, rest, final) = match book'' i s lim (q - t)
      in (evs ++ more, rest, final)
  where
    cands = [ r | r <- book, rSide r /= s, cross s lim (rPrice r) ]
    key r = if s == Buy then rPrice r else negate (rPrice r)
