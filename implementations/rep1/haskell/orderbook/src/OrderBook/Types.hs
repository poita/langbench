-- |
-- Module      : OrderBook.Types
-- Description : Core value types shared by the whole library.
--
-- All quantities and prices are 'Int', which is 64 bits wide on every
-- platform GHC 9.14 supports for this project; sums of quantities can exceed
-- 2^32 so no narrower type may be used.
module OrderBook.Types
  ( OrderId
  , Price
  , Qty
  , Side (..)
  , opposite
  , TimeInForce (..)
  , Command (..)
  , Event (..)
  ) where

import Data.ByteString (ByteString)

-- | Opaque order identifier, compared byte-for-byte.
type OrderId = ByteString

-- | Limit price (positive integer ticks).
type Price = Int

-- | Order quantity or a sum of quantities.
type Qty = Int

-- | Which side of the book an order is on.
data Side = Buy | Sell
  deriving (Eq, Ord, Show, Read, Enum, Bounded)

-- | The other side of the book.
opposite :: Side -> Side
opposite Buy  = Sell
opposite Sell = Buy

-- | How a limit order treats any quantity left after matching.
data TimeInForce
  = GoodTillCancel   -- ^ the remainder rests in the book (plain @LIMIT@)
  | ImmediateOrCancel -- ^ the remainder is discarded (@IOC@)
  | FillOrKill       -- ^ fill completely or not at all (@FOK@)
  deriving (Eq, Ord, Show, Read, Enum, Bounded)

-- | An input command.
data Command
  = Limit !OrderId !Side !Price !Qty !TimeInForce
  | Market !OrderId !Side !Qty
  | Cancel !OrderId
  | Replace !OrderId !Price !Qty
  | Snapshot                -- ^ the @BOOK@ command
  deriving (Eq, Show)

-- | An output event.
data Event
  = Trade !OrderId !OrderId !Price !Qty
    -- ^ taker id, maker id, maker price, quantity
  | Rest !OrderId
  | Cancelled !OrderId !Qty
    -- ^ id and the quantity that was left unfilled
  | Reject !OrderId
  | Filled !OrderId
  | BidLevel !Price !Qty !Int
    -- ^ price, total quantity, number of orders
  | AskLevel !Price !Qty !Int
  | EndOfBook
  deriving (Eq, Show)
