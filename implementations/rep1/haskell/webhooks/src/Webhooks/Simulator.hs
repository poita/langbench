{-# LANGUAGE BangPatterns #-}

-- | A deterministic webhook delivery simulator.
--
-- Events are fanned out to the endpoints whose filter matches, each pair
-- becoming a /delivery/. Every delivery is signed once, then attempted at the
-- event time and retried on a fixed schedule ('retryDelays') until it succeeds,
-- the endpoint answers @410 Gone@, or eight attempts have been made. Endpoints
-- respond from a fixed script.
module Webhooks.Simulator
  ( -- * Input
    Endpoint (..)
  , Filter (..)
  , Response (..)
  , Event (..)
  , matches
    -- * Output
  , Result (..)
  , Attempt (..)
  , Outcome (..)
  , Delivery (..)
  , Status (..)
    -- * Running
  , simulate
  , retryDelays
  , maxAttempts
  , renderResult
  ) where

import Control.Monad.ST (ST, runST)
import Data.Array (Array, bounds, listArray, (!))
import Data.Array.Base (unsafeRead, unsafeWrite)
import Data.Array.ST (STUArray, newArray)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Char8 as BC
import Webhooks.Heap (Heap)
import qualified Webhooks.Heap as Heap
import Webhooks.Signature (signatureHeader)

-- | Which events an endpoint receives.
data Filter
  = AllEvents          -- ^ the @*@ filter
  | Types [ByteString] -- ^ events whose type equals one of these
  deriving (Eq, Show)

-- | One scripted endpoint response.
data Response
  = Status !Int -- ^ an HTTP status code
  | Timeout
  deriving (Eq, Show)

-- | A receiving endpoint.
data Endpoint = Endpoint
  { endpointId :: ByteString
  , endpointKeys :: [ByteString]
    -- ^ raw signing keys, in order
  , endpointFilter :: Filter
  , endpointScript :: [Response]
    -- ^ responses by attempt number; the last one repeats forever. Must be
    -- non-empty.
  }
  deriving (Eq, Show)

-- | An event to deliver.
data Event = Event
  { eventId :: ByteString
  , eventTime :: !Int
    -- ^ enqueue time, Unix seconds (also the @webhook-timestamp@)
  , eventType :: ByteString
  , eventPayload :: ByteString
  }
  deriving (Eq, Show)

-- | Does the event go to the endpoint?
matches :: Endpoint -> Event -> Bool
matches ep ev = case endpointFilter ep of
  AllEvents -> True
  Types ts -> eventType ev `elem` ts

-- | What an attempt produced.
data Outcome = Success | Failure | TimedOut | Gone
  deriving (Eq, Show)

-- | Final state of a delivery.
data Status = Delivered | Failed | Disabled
  deriving (Eq, Show)

-- | One recorded attempt.
data Attempt = Attempt
  { attemptSeq :: !Int         -- ^ 1-based, in processing order
  , attemptEvent :: ByteString
  , attemptEndpoint :: ByteString
  , attemptNumber :: !Int      -- ^ 1-based, within the delivery
  , attemptTime :: !Int
  , attemptOutcome :: Outcome
  , attemptCode :: Maybe Int   -- ^ 'Nothing' for a timeout
  }
  deriving (Eq, Show)

-- | A delivery of one event to one endpoint.
data Delivery = Delivery
  { deliveryEvent :: ByteString
  , deliveryEndpoint :: ByteString
  , deliveryStatus :: Status
  , deliveryAttempts :: !Int
  , deliveryLastTime :: Maybe Int
  , deliveryHeader :: ByteString
    -- ^ the @webhook-signature@ header value
  }
  deriving (Eq, Show)

-- | The simulation's complete output.
data Result = Result
  { resultAttempts :: [Attempt]
    -- ^ in processing order
  , resultDeliveries :: [Delivery]
    -- ^ in creation order (events, then endpoints, in declaration order)
  }
  deriving (Eq, Show)

-- | Maximum number of attempts per delivery.
maxAttempts :: Int
maxAttempts = 8

-- | Seconds between attempt @n@ and attempt @n+1@: 5s, 5m, 30m, 2h, 5h, 10h, 10h.
retryDelays :: [Int]
retryDelays = [5, 300, 1800, 7200, 18000, 36000, 36000]

-- Delivery status codes in the mutable state array.
stPending, stDelivered, stFailed, stDisabled :: Int
stPending = 0
stDelivered = 1
stFailed = 2
stDisabled = 3

-- | A delivery as created: event, endpoint index and endpoint.
data Planned = Planned
  { pEvent :: Event
  , pEpIx :: !Int
  , pEndpoint :: Endpoint
  }

-- | Run the simulation.
--
-- Each delivery's signature header is computed exactly once. Scheduling uses
-- a min-heap keyed on @(time, delivery number)@, one entry per delivery.
simulate :: [Endpoint] -> [Event] -> Result
simulate endpoints events = runST (simulateST endpoints events)

simulateST :: forall s. [Endpoint] -> [Event] -> ST s Result
simulateST endpoints events = do
  let planned =
        [ Planned ev ix ep
        | ev <- events
        , (ix, ep) <- zip [0 ..] endpoints
        , matches ep ev
        ]
      nD = length planned
      nE = length endpoints
      plan = listArray (0, nD - 1) planned :: Array Int Planned
      scriptArr = listArray (0, nE - 1) (map (toArr . endpointScript) endpoints) :: Array Int (Array Int Response)
      toArr rs = listArray (0, length rs - 1) rs :: Array Int Response
      headers = listArray (0, nD - 1) (map header planned) :: Array Int ByteString
      header p =
        let ev = pEvent p
         in signatureHeader (endpointKeys (pEndpoint p)) (eventId ev) (showInt (eventTime ev)) (eventPayload ev)
  cursor <- newArray (0, max 0 (nE - 1)) 0 :: ST s (STUArray s Int Int)
  disabled <- newArray (0, max 0 (nE - 1)) False :: ST s (STUArray s Int Bool)
  status <- newArray (0, max 0 (nD - 1)) stPending :: ST s (STUArray s Int Int)
  count <- newArray (0, max 0 (nD - 1)) 0 :: ST s (STUArray s Int Int)
  lastT <- newArray (0, max 0 (nD - 1)) 0 :: ST s (STUArray s Int Int)
  let initial = Heap.fromList [(eventTime (pEvent (plan ! d)), d) | d <- [0 .. nD - 1]]

      loop :: Heap (Int, Int) -> Int -> [Attempt] -> ST s [Attempt]
      loop !heap !sq acc = case Heap.popMin heap of
        Nothing -> pure (reverse acc)
        Just ((t, d), heap') -> do
          let p = plan ! d
              ix = pEpIx p
          off <- unsafeRead disabled ix
          if off
            then unsafeWrite status d stDisabled >> loop heap' sq acc
            else do
              cur <- unsafeRead cursor ix
              unsafeWrite cursor ix (cur + 1)
              let rs = scriptArr ! ix
                  response = rs ! min cur (snd (bounds rs))
              n <- (+ 1) <$> unsafeRead count d
              unsafeWrite count d n
              unsafeWrite lastT d t
              let (outcome, code) = classify response
                  att = Attempt (sq + 1) (eventId (pEvent p)) (endpointId (pEndpoint p)) n t outcome code
                  finish st = unsafeWrite status d st >> loop heap' (sq + 1) (att : acc)
              case outcome of
                Success -> finish stDelivered
                Gone -> do
                  unsafeWrite disabled ix True
                  finish stFailed
                _
                  | n >= maxAttempts -> finish stFailed
                  | otherwise ->
                      loop (Heap.insert (t + retryDelays !! (n - 1), d) heap') (sq + 1) (att : acc)
  attempts <- loop initial 0 []
  deliveries <- mapM
    ( \d -> do
        let p = plan ! d
        st <- unsafeRead status d
        n <- unsafeRead count d
        lt <- unsafeRead lastT d
        pure
          Delivery
            { deliveryEvent = eventId (pEvent p)
            , deliveryEndpoint = endpointId (pEndpoint p)
            , deliveryStatus = toStatus st
            , deliveryAttempts = n
            , deliveryLastTime = if n == 0 then Nothing else Just lt
            , deliveryHeader = headers ! d
            }
    )
    [0 .. nD - 1]
  pure (Result attempts deliveries)
  where
    toStatus s
      | s == stDelivered = Delivered
      | s == stFailed = Failed
      | otherwise = Disabled

classify :: Response -> (Outcome, Maybe Int)
classify Timeout = (TimedOut, Nothing)
classify (Status c)
  | c >= 200 && c <= 299 = (Success, Just c)
  | c == 410 = (Gone, Just c)
  | otherwise = (Failure, Just c)

showInt :: Int -> ByteString
showInt = BC.pack . show

-- | Render a result in the line-oriented output format: a @sim A D@ header,
-- the attempt lines, then the delivery lines.
renderResult :: Result -> B.Builder
renderResult (Result atts dels) =
  line (B.string7 "sim " <> B.intDec (length atts) <> B.char7 ' ' <> B.intDec (length dels))
    <> foldMap attemptLine atts
    <> foldMap deliveryLine dels
  where
    line b = b <> B.char7 '\n'
    sp = B.char7 ' '
    attemptLine a =
      line $
        B.string7 "attempt " <> B.intDec (attemptSeq a)
          <> sp <> B.byteString (attemptEvent a)
          <> sp <> B.byteString (attemptEndpoint a)
          <> sp <> B.intDec (attemptNumber a)
          <> sp <> B.intDec (attemptTime a)
          <> sp <> B.string7 (outcomeName (attemptOutcome a))
          <> sp <> maybe (B.char7 '-') B.intDec (attemptCode a)
    deliveryLine d =
      line $
        B.string7 "delivery " <> B.byteString (deliveryEvent d)
          <> sp <> B.byteString (deliveryEndpoint d)
          <> sp <> B.string7 (statusName (deliveryStatus d))
          <> sp <> B.intDec (deliveryAttempts d)
          <> sp <> maybe (B.char7 '-') B.intDec (deliveryLastTime d)
          <> sp <> B.byteString (deliveryHeader d)
    outcomeName o = case o of
      Success -> "success"
      Failure -> "failure"
      TimedOut -> "timeout"
      Gone -> "gone"
    statusName s = case s of
      Delivered -> "delivered"
      Failed -> "failed"
      Disabled -> "disabled"
