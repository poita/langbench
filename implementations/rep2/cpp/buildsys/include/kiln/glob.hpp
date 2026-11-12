// Glob patterns (`*`, `?`, `[...]`, `**`) over `/`-separated strings.
#pragma once

#include <bitset>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace kiln {

/// A compiled glob pattern.
class GlobPattern {
 public:
  /// Compiles `pattern`; returns nullopt if it is malformed (empty, leading or
  /// trailing `/`, empty component, bad character class).
  static std::optional<GlobPattern> compile(std::string_view pattern);

  /// True if the pattern matches the whole candidate string.
  bool matches(std::string_view candidate) const;

  /// The longest literal prefix of the pattern that every possible match must
  /// start with. Used to narrow a sorted index scan.
  const std::string& literalPrefix() const noexcept { return prefix_; }

 private:
  struct Item {
    enum Kind { Star, Any, Class, Literal } kind;
    char ch = 0;
    std::bitset<256> set;  // for Class (already negated if needed)
  };
  struct Component {
    bool doubleStar = false;
    std::vector<Item> items;
  };

  static bool matchComponent(const Component& c, std::string_view s);

  std::vector<Component> comps_;
  std::string prefix_;
};

}  // namespace kiln
