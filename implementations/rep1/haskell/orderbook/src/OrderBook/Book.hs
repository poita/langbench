{-# LANGUAGE BangPatterns #-}
-- |
-- Module      : OrderBook.Book
-- Description : The persistent order-book data structure (no matching logic).
--
-- A 'Book' holds two sides of price levels. Each side is an 'IntMap' from
-- price to 'Level', so the best price is found with 'IntMap.lookupMin' /
-- 'IntMap.lookupMax' and an emptied level is dropped in O(min(P, W)) where
-- W is the word size. A level keeps its FIFO queue as an 'IntMap' keyed by a
-- monotonically increasing arrival sequence number, which gives
--
--   * O(1)-ish append at the back (largest key),
--   * O(1)-ish pop of the front (smallest key),
--   * removal of any order from the middle without scanning the queue,
--
-- together with the level's total quantity and order count, which are
-- maintained incrementally. A 'Map' from order id to the order's location
-- serves @CANCEL@ and @REPLACE@.
--
-- Everything here is purely functional; "OrderBook.Engine" builds the
-- matching rules on top of these primitives.
module OrderBook.Book
  ( -- * Book
    Book
  , empty
  , size
    -- * Levels
  , Level (..)
  , Entry (..)
    -- * Queries
  , bestLevel
  , levelsFrom
  , frontEntry
  , lookupOrder
  , Resting (..)
  , snapshot
    -- * Updates
  , insertOrder
  , removeOrder
  , reduceOrder
  , popFront
  ) where

import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict as M

import OrderBook.Types

-- | One resting order inside a level's queue.
data Entry = Entry
  { entryId  :: !OrderId
  , entryQty :: !Qty      -- ^ remaining quantity, always >= 1
  } deriving (Eq, Show)

-- | A non-empty price level.
data Level = Level
  { levelTotal :: !Qty                 -- ^ sum of remaining quantities
  , levelCount :: !Int                 -- ^ number of orders
  , levelQueue :: !(IM.IntMap Entry)   -- ^ FIFO queue keyed by arrival number
  } deriving (Eq, Show)

-- | Where a resting order lives; the value of the id index.
data Resting = Resting
  { restingSide  :: !Side
  , restingPrice :: !Price
  , restingSeq   :: !Int
  } deriving (Eq, Show)

-- | An order book. Construct with 'empty'.
data Book = Book
  { bookBids  :: !(IM.IntMap Level)
  , bookAsks  :: !(IM.IntMap Level)
  , bookIndex :: !(M.Map OrderId Resting)
  , bookSeq   :: !Int
  }

-- | The empty book.
empty :: Book
empty = Book IM.empty IM.empty M.empty 0

-- | Number of resting orders.
size :: Book -> Int
size = M.size . bookIndex

sideMap :: Side -> Book -> IM.IntMap Level
sideMap Buy  = bookBids
sideMap Sell = bookAsks

setSide :: Side -> IM.IntMap Level -> Book -> Book
setSide Buy  m b = b { bookBids = m }
setSide Sell m b = b { bookAsks = m }

-- | The best level of a side (highest bid / lowest ask) with its price.
bestLevel :: Side -> Book -> Maybe (Price, Level)
bestLevel Buy  = IM.lookupMax . bookBids
bestLevel Sell = IM.lookupMin . bookAsks

-- | All levels of a side, best first (lazily).
levelsFrom :: Side -> Book -> [(Price, Level)]
levelsFrom Buy  = IM.toDescList . bookBids
levelsFrom Sell = IM.toAscList . bookAsks

-- | The order at the front of a level's queue (the next maker).
frontEntry :: Level -> Maybe Entry
frontEntry = fmap (snd . fst) . IM.minViewWithKey . levelQueue

-- | Find a resting order by id.
lookupOrder :: OrderId -> Book -> Maybe (Resting, Entry)
lookupOrder oid b = do
  r <- M.lookup oid (bookIndex b)
  lvl <- IM.lookup (restingPrice r) (sideMap (restingSide r) b)
  e <- IM.lookup (restingSeq r) (levelQueue lvl)
  pure (r, e)

-- | Both sides as @(bids best-first, asks best-first)@ of
-- @(price, total quantity, order count)@.
snapshot :: Book -> ([(Price, Qty, Int)], [(Price, Qty, Int)])
snapshot b = (side Buy, side Sell)
  where
    side s = [ (p, levelTotal l, levelCount l) | (p, l) <- levelsFrom s b ]

-- | Append an order to the back of the queue at its price. The id must not
-- already be resting.
insertOrder :: Side -> Price -> OrderId -> Qty -> Book -> Book
insertOrder side price oid qty b =
  setSide side m' b
    { bookIndex = M.insert oid (Resting side price sq) (bookIndex b)
    , bookSeq = sq + 1
    }
  where
    !sq = bookSeq b
    !e = Entry oid qty
    m' = IM.alter add price (sideMap side b)
    add Nothing  = Just $! Level qty 1 (IM.singleton sq e)
    add (Just l) = Just $! Level (levelTotal l + qty) (levelCount l + 1)
                                 (IM.insert sq e (levelQueue l))

-- | Replace a level's queue, dropping the level when it becomes empty.
putLevel :: Side -> Price -> Level -> Book -> Book
putLevel side price l b
  | levelCount l == 0 = setSide side (IM.delete price m) b
  | otherwise         = setSide side (IM.insert price l m) b
  where m = sideMap side b

-- | Remove a resting order wherever it is, returning its location and
-- remaining quantity.
removeOrder :: OrderId -> Book -> Maybe (Resting, Qty, Book)
removeOrder oid b = do
  (r, e) <- lookupOrder oid b
  let side = restingSide r
      price = restingPrice r
  lvl <- IM.lookup price (sideMap side b)
  let lvl' = Level (levelTotal lvl - entryQty e) (levelCount lvl - 1)
                   (IM.delete (restingSeq r) (levelQueue lvl))
      b' = putLevel side price lvl' b { bookIndex = M.delete oid (bookIndex b) }
  pure (r, entryQty e, b')

-- | Set a resting order's remaining quantity in place (keeps its queue
-- position). Does nothing if the id is not resting.
reduceOrder :: OrderId -> Qty -> Book -> Book
reduceOrder oid q b = case lookupOrder oid b of
  Nothing -> b
  Just (r, e) ->
    let side = restingSide r
        price = restingPrice r
        upd l = l { levelTotal = levelTotal l - entryQty e + q
                  , levelQueue = IM.insert (restingSeq r) e { entryQty = q }
                                           (levelQueue l) }
    in setSide side (IM.adjust upd price (sideMap side b)) b

-- | Remove the order at the front of the best level of a side, or shrink it
-- to the given new remaining quantity (when positive). Used by matching:
-- @popFront side price newQty@ where @price@ is the best level's price.
-- Returns the updated book.
popFront :: Side -> Price -> Qty -> Book -> Book
popFront side price newQty b =
  case IM.lookup price (sideMap side b) >>= \l -> fmap ((,) l) (IM.minViewWithKey (levelQueue l)) of
    Nothing -> b
    Just (l, ((sq, e), rest))
      | newQty <= 0 ->
          putLevel side price
            (Level (levelTotal l - entryQty e) (levelCount l - 1) rest)
            b { bookIndex = M.delete (entryId e) (bookIndex b) }
      | otherwise ->
          putLevel side price
            (Level (levelTotal l - entryQty e + newQty) (levelCount l)
                   (IM.insert sq e { entryQty = newQty } rest))
            b
