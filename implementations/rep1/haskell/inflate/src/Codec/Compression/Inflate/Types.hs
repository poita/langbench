-- |
-- Module      : Codec.Compression.Inflate.Types
-- Description : Error type shared by the decoder modules.
module Codec.Compression.Inflate.Types
  ( InflateError (..)
  , describeError
  ) where

import Control.Exception (Exception)

-- | Every way in which a DEFLATE stream can be rejected.
data InflateError
  = UnexpectedEnd
    -- ^ The stream ended before the final block was complete.
  | InvalidBlockType
    -- ^ A block header had @BTYPE = 3@.
  | StoredLengthMismatch
    -- ^ A stored block's @NLEN@ is not the one's complement of @LEN@.
  | TooManyCodes
    -- ^ A dynamic header has @HLIT > 29@ or @HDIST > 29@.
  | InvalidCodeLengthCode
    -- ^ The code-length code is over-subscribed or incomplete.
  | InvalidLiteralLengthCode
    -- ^ The literal/length code is over-subscribed or incomplete.
  | InvalidDistanceCode
    -- ^ The distance code is over-subscribed or incomplete.
  | MissingEndOfBlock
    -- ^ The literal/length code gives no length to symbol 256.
  | RepeatWithoutPrevious
    -- ^ Code-length symbol 16 appeared as the first code length.
  | RepeatOverflow
    -- ^ A code-length repeat runs past the declared number of lengths.
  | InvalidHuffmanCode
    -- ^ A bit pattern does not correspond to any code of an incomplete table.
  | InvalidLengthSymbol
    -- ^ Literal/length symbol 286 or 287 was decoded.
  | InvalidDistanceSymbol
    -- ^ Distance symbol 30 or 31 was decoded.
  | NoDistanceCodes
    -- ^ A length code was decoded but the block has no distance codes.
  | DistanceTooFar
    -- ^ A back-reference reaches before the start of the output.
  | TrailingData
    -- ^ Whole bytes remain after the final block.
  deriving (Eq, Ord, Show, Enum, Bounded)

instance Exception InflateError

-- | A short human-readable description of an error.
describeError :: InflateError -> String
describeError e = case e of
  UnexpectedEnd            -> "stream ends before the final block is complete"
  InvalidBlockType         -> "invalid block type 3"
  StoredLengthMismatch     -> "stored block LEN/NLEN mismatch"
  TooManyCodes             -> "HLIT or HDIST out of range"
  InvalidCodeLengthCode    -> "invalid code-length code"
  InvalidLiteralLengthCode -> "invalid literal/length code"
  InvalidDistanceCode      -> "invalid distance code"
  MissingEndOfBlock        -> "no end-of-block code"
  RepeatWithoutPrevious    -> "code-length repeat with no previous length"
  RepeatOverflow           -> "code-length repeat overflows the length table"
  InvalidHuffmanCode       -> "bit pattern is not a valid Huffman code"
  InvalidLengthSymbol      -> "invalid literal/length symbol (286 or 287)"
  InvalidDistanceSymbol    -> "invalid distance symbol (30 or 31)"
  NoDistanceCodes          -> "length code in a block with no distance codes"
  DistanceTooFar           -> "distance exceeds the output produced so far"
  TrailingData             -> "data after the final block"
