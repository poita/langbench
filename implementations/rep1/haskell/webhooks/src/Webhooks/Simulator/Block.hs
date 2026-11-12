-- | Reading and validating a @simulate@ block of the command stream.
module Webhooks.Simulator.Block
  ( readBlock
  , parseEndpointLine
  , parseEventLine
  , maxEndpoints
  , maxEvents
  ) where

import qualified Data.ByteString as BS
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import qualified Data.Set as Set
import Webhooks.Field (isBlank, parseInt, parseName, splitFields)
import Webhooks.Hex (parseHexField)
import Webhooks.Secret (parseSecrets)
import Webhooks.Simulator (Endpoint (..), Event (..), Filter (..), Response (..))

-- | At most this many @endpoint@ lines.
maxEndpoints :: Int
maxEndpoints = 64

-- | At most this many @event@ lines.
maxEvents :: Int
maxEvents = 20000

-- | Parse @endpoint \<ep-id\> \<secrets\> \<filter\> \<script\>@ from its fields
-- (including the leading command word).
parseEndpointLine :: [ByteString] -> Maybe Endpoint
parseEndpointLine [_, ident, secrets, filt, script] =
  Endpoint <$> parseName ident <*> parseSecrets secrets <*> parseFilter filt <*> parseScript script
parseEndpointLine _ = Nothing

-- | Parse @event \<ev-id\> \<ts\> \<type\> \<payload-hex\>@ from its fields.
parseEventLine :: [ByteString] -> Maybe Event
parseEventLine [_, ident, ts, typ, payload] =
  Event <$> parseName ident <*> parseInt ts <*> parseName typ <*> parseHexField payload
parseEventLine _ = Nothing

parseFilter :: ByteString -> Maybe Filter
parseFilter f
  | f == BC.singleton '*' = Just AllEvents
  | null parts || length parts > 16 = Nothing
  | otherwise = Types <$> traverse parseName parts
  where
    parts = BS.split 44 f

parseScript :: ByteString -> Maybe [Response]
parseScript s
  | null parts || length parts > 64 = Nothing
  | otherwise = traverse response parts
  where
    parts = BS.split 44 s
    response r
      | r == BC.pack "timeout" = Just Timeout
      | BS.length r == 3, BS.all (\c -> c >= 48 && c <= 57) r, c <- code r, c >= 100, c <= 599 = Just (Status c)
      | otherwise = Nothing
    code = BS.foldl' (\a c -> a * 10 + fromIntegral c - 48) 0

data Phase = Endpoints | Events deriving (Eq)

data Acc = Acc
  { accPhase :: !Phase
  , accEndpoints :: [Endpoint] -- reversed
  , accEvents :: [Event]       -- reversed
  , accEpIds :: Set.Set ByteString
  , accEvIds :: Set.Set ByteString
  , accNEp :: !Int
  , accNEv :: !Int
  }

-- | Consume the lines following a @simulate@ command, up to and including
-- the terminating @end@ line. Returns the endpoints and events, or 'Nothing'
-- if the block is malformed, together with the unconsumed remainder. On a
-- malformed block, lines are still consumed up to @end@ (or end of input).
readBlock :: [ByteString] -> (Maybe ([Endpoint], [Event]), [ByteString])
readBlock = go (Just (Acc Endpoints [] [] Set.empty Set.empty 0 0))
  where
    go _ [] = (Nothing, [])
    go acc (l : ls)
      | isBlank l = go acc ls
      | l == BC.pack "end" = (finish acc, ls)
      | otherwise = go (acc >>= step (splitFields l)) ls

    finish acc = do
      a <- acc
      if accNEp a == 0 then Nothing else Just (reverse (accEndpoints a), reverse (accEvents a))

    step fields a = case fields of
      (c : _)
        | c == BC.pack "endpoint", accPhase a == Endpoints -> do
            ep <- parseEndpointLine fields
            if accNEp a >= maxEndpoints || endpointId ep `Set.member` accEpIds a
              then Nothing
              else
                Just
                  a { accEndpoints = ep : accEndpoints a
                    , accEpIds = Set.insert (endpointId ep) (accEpIds a)
                    , accNEp = accNEp a + 1
                    }
        | c == BC.pack "event" -> do
            ev <- parseEventLine fields
            if accNEv a >= maxEvents || eventId ev `Set.member` accEvIds a
              then Nothing
              else
                Just
                  a { accPhase = Events
                    , accEvents = ev : accEvents a
                    , accEvIds = Set.insert (eventId ev) (accEvIds a)
                    , accNEv = accNEv a + 1
                    }
      _ -> Nothing
