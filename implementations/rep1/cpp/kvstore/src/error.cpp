#include "tessera/error.hpp"

namespace tessera {

const char* error_name(ErrorKind kind) {
  switch (kind) {
    case ErrorKind::Syntax: return "syntax";
    case ErrorKind::UnknownCommand: return "unknown-command";
    case ErrorKind::BadUtf8: return "bad-utf8";
    case ErrorKind::IntRange: return "int-range";
    case ErrorKind::DupField: return "dup-field";
    case ErrorKind::Depth: return "depth";
    case ErrorKind::BadKey: return "bad-key";
    case ErrorKind::BadPath: return "bad-path";
    case ErrorKind::NotFound: return "not-found";
    case ErrorKind::NoField: return "no-field";
    case ErrorKind::NotObject: return "not-object";
    case ErrorKind::DocTooLarge: return "doc-too-large";
    case ErrorKind::IndexKeyTooLong: return "index-key-too-long";
    case ErrorKind::IndexExists: return "index-exists";
    case ErrorKind::IndexMissing: return "index-missing";
    case ErrorKind::IndexLimit: return "index-limit";
    case ErrorKind::TxnActive: return "txn-active";
    case ErrorKind::NoTxn: return "no-txn";
  }
  return "syntax";
}

}  // namespace tessera
