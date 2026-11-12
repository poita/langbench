#include "inflate/error.hpp"

namespace inflate {

const char* to_string(Error e) noexcept {
  switch (e) {
    case Error::None: return "no error";
    case Error::TruncatedInput: return "stream ended prematurely";
    case Error::InvalidBlockType: return "invalid block type (3)";
    case Error::StoredLengthMismatch: return "stored block LEN/NLEN mismatch";
    case Error::TooManyCodes: return "too many literal/length or distance codes";
    case Error::InvalidCodeLengthCode: return "invalid code-length code";
    case Error::InvalidLiteralCode: return "invalid literal/length code";
    case Error::InvalidDistanceCode: return "invalid distance code";
    case Error::InvalidRepeat: return "invalid code-length repeat";
    case Error::InvalidCode: return "bit pattern is not a valid code";
    case Error::InvalidSymbol: return "invalid literal/length or distance symbol";
    case Error::NoDistanceCodes: return "length code in a block without distance codes";
    case Error::DistanceTooFar: return "distance exceeds output produced so far";
    case Error::TrailingData: return "trailing data after final block";
    case Error::OutputLimitExceeded: return "output size limit exceeded";
    case Error::InvalidHex: return "invalid hexadecimal input";
  }
  return "unknown error";
}

}  // namespace inflate
