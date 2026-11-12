{-# LANGUAGE BangPatterns #-}
-- |
-- Module      : Text.Regex.Backtrack.Batch
-- Description : The line-oriented batch format used by the command-line tool.
--
-- Input is @N@, then for each pattern a pattern line, a count @M@ and @M@
-- subject lines. Output has one line per subject: @no@, or
-- @match START END|g1s,g1e|-|...@ with @-@ for unset groups.
module Text.Regex.Backtrack.Batch
  ( BatchError (..)
  , runBatch
  , formatResult
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Unsafe as BU

import Text.Regex.Backtrack

-- | Why a batch could not be processed.
data BatchError
  = MalformedInput String
    -- ^ Truncated input or a bad count line.
  | BadPattern Int ParseError
    -- ^ The (1-based) pattern failed to parse.
  deriving (Eq, Show)

-- | Process a whole batch. Output is handed to the callback one chunk per
-- pattern, so the full output never needs to be resident. Processing stops
-- at the first error (output already produced stays produced).
runBatch :: (BB.Builder -> IO ()) -> B.ByteString -> IO (Either BatchError ())
runBatch emit input0 =
  case readCount input0 of
    Left e -> pure (Left e)
    Right (n, rest0) -> loop 1 n rest0
  where
    loop :: Int -> Int -> B.ByteString -> IO (Either BatchError ())
    loop !idx !n !inp
      | idx > n = pure (Right ())
      | otherwise = case nextLine inp of
          Nothing -> pure (Left (MalformedInput ("missing pattern " ++ show idx)))
          Just (pat, afterPat) -> case readCount afterPat of
            Left e -> pure (Left e)
            Right (m, afterCount) -> case compile (BC.unpack pat) of
              Left pe -> pure (Left (BadPattern idx pe))
              Right re -> case skipLines m afterCount of
                Nothing -> pure (Left (MalformedInput ("pattern " ++ show idx ++ ": too few subjects")))
                Just rest -> do
                  emit (subjects re m afterCount)
                  loop (idx + 1) n rest

-- Lazily produce output for the next @m@ lines.
subjects :: Regex -> Int -> B.ByteString -> BB.Builder
subjects re = go
  where
    go !m !inp
      | m <= 0 = mempty
      | otherwise = case nextLine inp of
          Nothing -> mempty
          Just (line, rest) -> formatResult (matchBytes re line) <> go (m - 1) rest

-- | Render one result line (including the trailing newline).
formatResult :: Maybe Match -> BB.Builder
formatResult Nothing = BB.string7 "no\n"
formatResult (Just (Match s e gs)) =
  BB.string7 "match " <> BB.intDec s <> BB.char7 ' ' <> BB.intDec e
    <> foldMap (\g -> BB.char7 '|' <> grp g) gs
    <> BB.char7 '\n'
  where
    grp Nothing = BB.char7 '-'
    grp (Just (a, b)) = BB.intDec a <> BB.char7 ',' <> BB.intDec b

-- Split off the next line (without its terminator). A final line lacking a
-- newline is accepted.
nextLine :: B.ByteString -> Maybe (B.ByteString, B.ByteString)
nextLine inp
  | B.null inp = Nothing
  | otherwise = case B.elemIndex 10 inp of
      Nothing -> Just (inp, B.empty)
      Just i  -> Just (BU.unsafeTake i inp, BU.unsafeDrop (i + 1) inp)

skipLines :: Int -> B.ByteString -> Maybe B.ByteString
skipLines !m !inp
  | m <= 0 = Just inp
  | otherwise = nextLine inp >>= \(_, rest) -> skipLines (m - 1) rest

readCount :: B.ByteString -> Either BatchError (Int, B.ByteString)
readCount inp = case nextLine inp of
  Nothing -> Left (MalformedInput "missing count line")
  Just (l, rest) -> case BC.readInt l of
    Just (n, r) | B.null r, n >= 0 -> Right (n, rest)
    _ -> Left (MalformedInput ("bad count line: " ++ show (BC.unpack l)))
