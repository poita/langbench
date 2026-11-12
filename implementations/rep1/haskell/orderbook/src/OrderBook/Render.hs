-- |
-- Module      : OrderBook.Render
-- Description : Rendering events in the output format.
module OrderBook.Render
  ( renderEvent
  , renderEvents
  ) where

import Data.ByteString.Builder

import OrderBook.Types

sp :: Builder
sp = char7 ' '

-- | One event as a line, including the trailing newline.
renderEvent :: Event -> Builder
renderEvent ev = (<> char7 '\n') $ case ev of
  Trade t m p q  -> string7 "TRADE " <> byteString t <> sp <> byteString m
                      <> sp <> intDec p <> sp <> intDec q
  Rest i         -> string7 "REST " <> byteString i
  Cancelled i q  -> string7 "CANCEL " <> byteString i <> sp <> intDec q
  Reject i       -> string7 "REJECT " <> byteString i
  Filled i       -> string7 "FILLED " <> byteString i
  BidLevel p q n -> string7 "BID " <> intDec p <> sp <> intDec q <> sp <> intDec n
  AskLevel p q n -> string7 "ASK " <> intDec p <> sp <> intDec q <> sp <> intDec n
  EndOfBook      -> string7 "--"

-- | Many events, concatenated.
renderEvents :: [Event] -> Builder
renderEvents = foldr ((<>) . renderEvent) mempty
