#include "depresolve/resolver.hpp"

#include <algorithm>
#include <cstdint>
#include <stdexcept>

namespace depresolve {

namespace {

constexpr std::uint32_t kNil = ~std::uint32_t{0};
constexpr std::uint32_t kUnset = ~std::uint32_t{0};

// A cell of the pending-requirements list. Lists share tails, so pushing a
// version's requirements in front of the rest never copies the rest.
struct Node {
  const Requirement* requirement;
  std::uint32_t next;
};

// A package that was chosen and may still have untried candidates.
struct ChoicePoint {
  PackageId package;
  std::uint32_t next_candidate;  // index of the next version to try
  std::uint32_t last;            // one past the last candidate index
  std::uint32_t rest;            // pending list that follows this package's requirements
  std::uint32_t arena_mark;      // arena size when the choice point was created
};

class Search {
 public:
  Search(const Registry& registry, const std::vector<Requirement>& root)
      : registry_(registry), root_(root), chosen_(registry.package_count(), kUnset) {}

  Resolution run() {
    Resolution result;
    std::uint32_t pending = push_list(root_, kNil);

    for (;;) {
      if (pending == kNil) {
        result.satisfiable = true;
        break;
      }
      ++result.stats.steps;
      const Node node = arena_[pending];
      const Requirement& req = *node.requirement;
      bool failed = false;

      if (!req.has_candidates()) {
        // No version satisfies the range, so neither can a chosen one.
        failed = true;
      } else if (chosen_[req.package] != kUnset) {
        if (req.accepts_index(chosen_[req.package])) {
          pending = node.next;
        } else {
          failed = true;
        }
      } else {
        stack_.push_back({req.package, req.first + 1, req.last, node.next,
                          static_cast<std::uint32_t>(arena_.size())});
        chosen_[req.package] = req.first;
        ++result.stats.choice_points;
        pending = push_list(registry_.versions(req.package)[req.first].requirements, node.next);
      }

      if (!failed) continue;

      // Chronological backtracking: the most recent choice point that still
      // has an untried candidate takes its next-newest candidate.
      for (;;) {
        if (stack_.empty()) {
          return result;  // unsatisfiable
        }
        ChoicePoint& cp = stack_.back();
        arena_.resize(cp.arena_mark);
        if (cp.next_candidate < cp.last) {
          const std::uint32_t index = cp.next_candidate++;
          chosen_[cp.package] = index;
          ++result.stats.choice_points;
          pending = push_list(registry_.versions(cp.package)[index].requirements, cp.rest);
          break;
        }
        chosen_[cp.package] = kUnset;
        stack_.pop_back();
      }
    }

    for (PackageId id = 0; id < chosen_.size(); ++id) {
      if (chosen_[id] == kUnset) continue;
      result.picks.push_back({registry_.name(id), registry_.versions(id)[chosen_[id]].version});
    }
    std::sort(result.picks.begin(), result.picks.end(),
              [](const Pick& a, const Pick& b) { return a.name < b.name; });
    return result;
  }

 private:
  // Prepends `reqs` (keeping their order) to the list starting at `rest`.
  std::uint32_t push_list(const std::vector<Requirement>& reqs, std::uint32_t rest) {
    for (std::size_t i = reqs.size(); i-- > 0;) {
      arena_.push_back({&reqs[i], rest});
      rest = static_cast<std::uint32_t>(arena_.size() - 1);
    }
    return rest;
  }

  const Registry& registry_;
  const std::vector<Requirement>& root_;
  std::vector<std::uint32_t> chosen_;  // per package: index of the chosen version
  std::vector<Node> arena_;
  std::vector<ChoicePoint> stack_;
};

}  // namespace

Resolution resolve(const Registry& registry, const std::vector<Requirement>& root) {
  if (!registry.finalized()) throw std::logic_error("resolve requires a finalized Registry");
  return Search(registry, root).run();
}

Resolution resolve(const Registry& registry, const std::vector<Dependency>& root) {
  if (!registry.finalized()) throw std::logic_error("resolve requires a finalized Registry");
  return resolve(registry, registry.compile(root));
}

std::string format_resolution(const Resolution& resolution) {
  if (!resolution.satisfiable) return "unsatisfiable\n";
  std::string out;
  for (const Pick& pick : resolution.picks) {
    out += pick.name;
    out += ' ';
    out += pick.version.to_string();
    out += '\n';
  }
  return out;
}

std::string resolve_text(std::string_view input) {
  const Problem problem = parse_problem(input);
  return format_resolution(resolve(problem));
}

}  // namespace depresolve
