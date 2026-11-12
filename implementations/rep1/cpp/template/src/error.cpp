#include "jinjalite/error.hpp"

namespace jinjalite {

const char* to_string(ErrorKind kind) noexcept {
  switch (kind) {
    case ErrorKind::Syntax: return "syntax";
    case ErrorKind::Filter: return "filter";
    case ErrorKind::Undefined: return "undefined";
    case ErrorKind::Template: return "template";
    case ErrorKind::Type: return "type";
  }
  return "type";
}

}  // namespace jinjalite
