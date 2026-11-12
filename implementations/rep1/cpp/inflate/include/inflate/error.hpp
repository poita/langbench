#pragma once
/// \file error.hpp
/// Error codes reported by the decoder.

namespace inflate {

/// Reason a DEFLATE stream was rejected. `Error::None` means success.
enum class Error {
  None = 0,
  TruncatedInput,         ///< Stream ended before the final block was complete.
  InvalidBlockType,       ///< BTYPE == 3.
  StoredLengthMismatch,   ///< Stored block with LEN != ~NLEN.
  TooManyCodes,           ///< HLIT > 29 or HDIST > 29.
  InvalidCodeLengthCode,  ///< Code-length code over-subscribed or incomplete.
  InvalidLiteralCode,     ///< Literal/length code invalid or lacking end-of-block.
  InvalidDistanceCode,    ///< Distance code over-subscribed or incomplete.
  InvalidRepeat,          ///< Repeat code 16 with no previous length, or overflow.
  InvalidCode,            ///< Bit pattern matches no code of an incomplete table.
  InvalidSymbol,          ///< Literal/length symbol 286/287 or distance symbol 30/31.
  NoDistanceCodes,        ///< Length code decoded but the block has no distance codes.
  DistanceTooFar,         ///< Back-reference reaches before the start of the output.
  TrailingData,           ///< Whole bytes remain after the final block.
  OutputLimitExceeded,    ///< Output would exceed Options::max_output.
  InvalidHex,             ///< (hex helpers) input is not valid hexadecimal.
};

/// Human-readable, static description of an error code.
const char* to_string(Error e) noexcept;

}  // namespace inflate
