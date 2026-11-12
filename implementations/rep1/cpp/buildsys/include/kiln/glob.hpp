// Glob patterns over `/`-separated strings.
#pragma once

#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace kiln {

/// A compiled glob pattern: `*`, `?`, `[...]` classes, and `**` as a whole
/// component matching zero or more components.
class GlobPattern {
 public:
  /// Returns nullopt for a malformed pattern (empty, leading/trailing/empty
  /// component, malformed character class).
  static std::optional<GlobPattern> compile(std::string_view pattern);

  /// Matches the whole candidate. The candidate is split at every `/`, keeping
  /// empty components.
  bool matches(std::string_view candidate) const;

  /// Wildcard-free leading bytes of the pattern (a trailing `/` removed), so
  /// every match starts with this prefix. Used to narrow index scans.
  const std::string& literal_prefix() const { return prefix_; }

 private:
  struct Item {
    enum Kind { Literal, AnyOne, AnyRun, Class } kind;
    char ch = 0;                                         // Literal
    bool negate = false;                                 // Class
    std::vector<std::pair<unsigned char, unsigned char>> ranges;  // Class
  };
  struct Component {
    bool double_star = false;
    std::vector<Item> items;
  };

  static bool match_component(const std::vector<Item>& items, std::string_view s);

  std::vector<Component> components_;
  std::string prefix_;
};

}  // namespace kiln
