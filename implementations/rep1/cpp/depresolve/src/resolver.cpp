#include "depresolve/resolver.hpp"

#include <algorithm>
#include <limits>
#include <numeric>

namespace depresolve {

namespace {

constexpr std::uint32_t kNone = std::numeric_limits<std::uint32_t>::max();

// Node of the shared pending-requirement list.
struct PendingNode {
  std::uint32_t req;   // index into creqs_
  std::uint32_t next;  // next node, or kNone
};

// A package whose remaining candidates have not been tried yet.
struct ChoicePoint {
  PackageId package;
  std::uint32_t next;        // next candidate to try
  std::uint32_t end;         // one past the last candidate
  std::uint32_t rest;        // pending list that follows the requirement
  std::size_t nodes_size;    // arena size to restore
  std::size_t trail_size;    // trail size to restore
};

}  // namespace

Resolver::Resolver(const Registry& registry, std::span<const Requirement> root) {
  const std::size_t package_count = registry.package_count();
  names_.reserve(package_count);
  for (PackageId p = 0; p < package_count; ++p) names_.push_back(registry.name(p));

  // Group registry versions by package, newest first.
  auto versions = registry.versions();
  std::vector<std::uint32_t> order(versions.size());
  std::iota(order.begin(), order.end(), 0u);
  std::sort(order.begin(), order.end(), [&](std::uint32_t a, std::uint32_t b) {
    if (versions[a].package != versions[b].package) return versions[a].package < versions[b].package;
    return versions[a].version > versions[b].version;
  });

  // group_begin[p]..group_begin[p+1] is package p's slice of cands_.
  std::vector<std::uint32_t> group_begin(package_count + 1, 0);
  for (const auto& v : versions) ++group_begin[v.package + 1];
  for (std::size_t p = 0; p < package_count; ++p) group_begin[p + 1] += group_begin[p];

  // Flat requirement array: root first, then each candidate's requirements.
  std::vector<const Requirement*> sources;  // parallel to creqs_
  for (const auto& r : root) sources.push_back(&r);
  root_count_ = static_cast<std::uint32_t>(root.size());
  cands_.reserve(versions.size());
  for (std::uint32_t idx : order) {
    const PackageVersion& pv = versions[idx];
    Candidate c{pv.version, static_cast<std::uint32_t>(sources.size()), 0};
    for (const auto& r : pv.requirements) sources.push_back(&r);
    c.req_end = static_cast<std::uint32_t>(sources.size());
    cands_.push_back(c);
  }

  // Resolve each requirement's range to a contiguous candidate index range.
  creqs_.reserve(sources.size());
  for (const Requirement* r : sources) {
    auto first = cands_.begin() + group_begin[r->package];
    auto last = cands_.begin() + group_begin[r->package + 1];
    const Range& range = r->range;
    // Descending order: versions >= hi come first, then those in range, then < lo.
    auto lo_it = std::partition_point(first, last, [&](const Candidate& c) { return c.version >= range.hi(); });
    auto hi_it = std::partition_point(first, last, [&](const Candidate& c) { return c.version >= range.lo(); });
    auto lo = static_cast<std::uint32_t>(lo_it - cands_.begin());
    auto hi = static_cast<std::uint32_t>(hi_it - cands_.begin());
    if (hi < lo) hi = lo;  // empty range
    creqs_.push_back(CompiledReq{r->package, lo, hi});
  }
}

std::optional<Resolution> Resolver::resolve() {
  stats_ = ResolveStats{};
  std::vector<std::uint32_t> chosen(names_.size(), kNone);  // package -> candidate index
  std::vector<PackageId> trail;                              // packages chosen, in order
  std::vector<PendingNode> nodes;                            // arena for pending lists
  std::vector<ChoicePoint> choices;

  // Pushes requirements [begin, end) in front of `list`, preserving order.
  auto push_reqs = [&](std::uint32_t begin, std::uint32_t end, std::uint32_t list) {
    for (std::uint32_t i = end; i-- > begin;) {
      nodes.push_back(PendingNode{i, list});
      list = static_cast<std::uint32_t>(nodes.size() - 1);
    }
    return list;
  };

  // Picks the next candidate of `cp`, returns the new pending list.
  // `cp` may be popped (and thus invalidated) when its candidates run out.
  auto enter = [&](ChoicePoint& cp) {
    std::uint32_t cand = cp.next++;
    ++stats_.choices;
    chosen[cp.package] = cand;
    trail.push_back(cp.package);
    std::uint32_t list = push_reqs(cands_[cand].req_begin, cands_[cand].req_end, cp.rest);
    if (cp.next == cp.end) choices.pop_back();
    return list;
  };

  std::uint32_t head = push_reqs(0, root_count_, kNone);

  while (head != kNone) {
    const PendingNode node = nodes[head];
    const CompiledReq& req = creqs_[node.req];
    std::uint32_t cur = chosen[req.package];
    bool failed = false;
    if (cur != kNone) {
      if (cur >= req.lo && cur < req.hi) {
        head = node.next;
      } else {
        failed = true;
      }
    } else if (req.lo == req.hi) {
      failed = true;
    } else {
      choices.push_back(ChoicePoint{req.package, req.lo, req.hi, node.next, nodes.size(), trail.size()});
      head = enter(choices.back());
    }

    if (failed) {
      // Chronological backtracking: resume the most recent open choice point.
      if (choices.empty()) return std::nullopt;
      ChoicePoint& cp = choices.back();
      while (trail.size() > cp.trail_size) {
        chosen[trail.back()] = kNone;
        trail.pop_back();
      }
      nodes.resize(cp.nodes_size);
      head = enter(cp);
    }
  }

  Resolution result;
  for (PackageId p : trail) {
    result.packages.push_back(ResolvedPackage{names_[p], cands_[chosen[p]].version});
  }
  std::sort(result.packages.begin(), result.packages.end(),
            [](const ResolvedPackage& a, const ResolvedPackage& b) { return a.name < b.name; });
  return result;
}

std::optional<Resolution> resolve(const Problem& problem) {
  Resolver resolver(problem.registry, problem.root);
  return resolver.resolve();
}

}  // namespace depresolve
