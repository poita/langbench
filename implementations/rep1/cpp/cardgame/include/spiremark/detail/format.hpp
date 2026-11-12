// Internal helpers for rendering event-line fields.
#pragma once

#include <cstdint>
#include <string>

#include "spiremark/types.hpp"

namespace spiremark::detail {

struct P { int p; };                 ///< a player: A or B
struct O { std::int64_t oid; };      ///< an object: #7
struct C { std::int64_t cid; };      ///< a Chain entry: ~3
struct S { std::int64_t v; };        ///< a signed number with explicit sign

inline void put(std::string& s, const std::string& v) { s += v; }
inline void put(std::string& s, const char* v) { s += v; }
inline void put(std::string& s, int v) { s += std::to_string(v); }
inline void put(std::string& s, long v) { s += std::to_string(v); }
inline void put(std::string& s, long long v) { s += std::to_string(v); }
inline void put(std::string& s, unsigned long v) { s += std::to_string(v); }
inline void put(std::string& s, P v) { s += player_char(v.p); }
inline void put(std::string& s, O v) { s += '#'; s += std::to_string(v.oid); }
inline void put(std::string& s, C v) { s += '~'; s += std::to_string(v.cid); }
inline void put(std::string& s, S v) {
    if (v.v >= 0) s += '+';
    s += std::to_string(v.v);
}
inline void put(std::string& s, const Ref& v) { s += v.render(); }

/// "NAME f1 f2 ..." — fields separated by single spaces.
template <class... A>
std::string build(const char* name, const A&... fields) {
    std::string s = name;
    ((s += ' ', put(s, fields)), ...);
    return s;
}

}  // namespace spiremark::detail
