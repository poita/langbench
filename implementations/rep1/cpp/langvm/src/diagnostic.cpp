#include "langvm/diagnostic.h"

namespace langvm {

const char* kindName(ErrorKind kind) {
  switch (kind) {
#define X(name, text) \
  case ErrorKind::name: return text;
    LANGVM_ERROR_KINDS(X)
#undef X
  }
  return "?";
}

std::string Diagnostic::toString() const {
  return std::string("error: ") + kindName(kind) + " at " + std::to_string(line) + ":" +
         std::to_string(col);
}

}  // namespace langvm
