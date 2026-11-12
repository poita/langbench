-- |
-- Module      : OrderBook.Parse
-- Description : Parsing the line-oriented command format.
module OrderBook.Parse
  ( parseCommand
  , parseCommands
  ) where

import qualified Data.ByteString.Char8 as C

import OrderBook.Types

-- | Parse one command line. Returns 'Nothing' for anything that is not a
-- well-formed command (the CLI input is guaranteed well formed, so callers
-- may treat this as an error).
parseCommand :: C.ByteString -> Maybe Command
parseCommand line = case C.split ' ' line of
  [kw, i, s, p, q] | kw == C.pack "LIMIT" -> limit i s p q GoodTillCancel
  [kw, i, s, p, q, f] | kw == C.pack "LIMIT" -> case C.unpack f of
    "IOC" -> limit i s p q ImmediateOrCancel
    "FOK" -> limit i s p q FillOrKill
    _     -> Nothing
  [kw, i, s, q] | kw == C.pack "MARKET" -> Market i <$> side s <*> int q
  [kw, i] | kw == C.pack "CANCEL" -> Just (Cancel i)
  [kw, i, p, q] | kw == C.pack "REPLACE" -> Replace i <$> int p <*> int q
  [kw] | kw == C.pack "BOOK" -> Just Snapshot
  _ -> Nothing
  where
    limit i s p q tif = (\sd pr qt -> Limit i sd pr qt tif) <$> side s <*> int p <*> int q
    side t = case C.unpack t of
      "BUY"  -> Just Buy
      "SELL" -> Just Sell
      _      -> Nothing
    int t = case C.readInt t of
      Just (n, rest) | C.null rest -> Just n
      _                            -> Nothing

-- | Parse a whole input document: a count @N@ on the first line followed by
-- up to @N@ command lines. Unparseable lines are skipped.
parseCommands :: C.ByteString -> [Command]
parseCommands input = case C.lines input of
  [] -> []
  (hdr : rest) ->
    let n = maybe 0 fst (C.readInt hdr)
    in [ c | Just c <- map parseCommand (take n rest) ]
