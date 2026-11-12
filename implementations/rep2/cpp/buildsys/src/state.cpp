#include "kiln/state.hpp"

#include "kiln/hash.hpp"
#include "kiln/path.hpp"

namespace kiln {

namespace {

bool startsWith(const std::string& s, const char* prefix) {
  return s.rfind(prefix, 0) == 0;
}

// Parses "<path> <hash>".
bool parsePathHash(std::string_view rem, PathHash& out) {
  std::size_t sp = rem.find(' ');
  if (sp == std::string_view::npos) return false;
  std::string_view path = rem.substr(0, sp);
  std::uint64_t h;
  if (!isWorkspacePath(path) || !parseHex16(rem.substr(sp + 1), h)) return false;
  out = {std::string(path), h};
  return true;
}

}  // namespace

BuildState BuildState::parse(const std::string& text) {
  BuildState result;
  if (text.empty() || text.back() != '\n') return result;
  std::vector<std::string> lines;
  std::size_t i = 0;
  while (i < text.size()) {
    std::size_t nl = text.find('\n', i);
    lines.push_back(text.substr(i, nl - i));
    i = nl + 1;
  }
  if (lines.empty() || lines[0] != "kiln-state 1") return result;

  BuildState parsed;
  std::size_t n = lines.size();
  std::size_t k = 1;
  while (k < n) {
    // step
    if (!startsWith(lines[k], "step ")) return result;
    std::string key = lines[k].substr(5);
    if (!isWorkspacePath(key)) return result;
    ++k;
    // cmd
    if (k >= n || !startsWith(lines[k], "cmd ") || lines[k].size() <= 4) return result;
    StateEntry e;
    e.cmd = lines[k].substr(4);
    ++k;
    PathHash ph;
    while (k < n && startsWith(lines[k], "in ")) {
      if (!parsePathHash(std::string_view(lines[k]).substr(3), ph)) return result;
      e.ins.push_back(ph);
      ++k;
    }
    while (k < n && startsWith(lines[k], "dep ")) {
      if (!parsePathHash(std::string_view(lines[k]).substr(4), ph)) return result;
      e.deps.push_back(ph);
      ++k;
    }
    while (k < n && startsWith(lines[k], "out ")) {
      if (!parsePathHash(std::string_view(lines[k]).substr(4), ph)) return result;
      e.outs.push_back(ph);
      ++k;
    }
    if (e.outs.empty()) return result;
    if (k >= n || lines[k] != "end") return result;
    ++k;
    if (e.outs.front().first != key) return result;
    if (!parsed.entries_.emplace(key, std::move(e)).second) return result;
  }
  return parsed;
}

BuildState BuildState::load(const Vfs& vfs) {
  Content c = vfs.read(".kiln-state");
  if (!c) return {};
  return parse(*c);
}

std::string BuildState::serialize() const {
  std::string out = "kiln-state 1\n";
  for (const auto& [key, e] : entries_) {
    out += "step " + key + "\n";
    out += "cmd " + e.cmd + "\n";
    for (const auto& [p, h] : e.ins) out += "in " + p + " " + toHex16(h) + "\n";
    for (const auto& [p, h] : e.deps) out += "dep " + p + " " + toHex16(h) + "\n";
    for (const auto& [p, h] : e.outs) out += "out " + p + " " + toHex16(h) + "\n";
    out += "end\n";
  }
  return out;
}

void BuildState::save(Vfs& vfs) const { vfs.write(".kiln-state", serialize()); }

const StateEntry* BuildState::find(const std::string& key) const {
  auto it = entries_.find(key);
  return it == entries_.end() ? nullptr : &it->second;
}

void BuildState::replace(const std::string& key, StateEntry entry) {
  entries_[key] = std::move(entry);
}

void BuildState::erase(const std::string& key) { entries_.erase(key); }

bool isFresh(const Step& step, const BuildState& state, const Vfs& vfs) {
  const StateEntry* e = state.find(step.primary());
  if (!e) return false;
  if (e->cmd != step.canonical) return false;
  std::vector<std::string> outs = step.fullOutputs();
  if (e->outs.size() != outs.size()) return false;
  for (std::size_t i = 0; i < outs.size(); ++i)
    if (e->outs[i].first != outs[i]) return false;
  std::vector<std::string> ins = step.fileInputs();
  if (e->ins.size() != ins.size()) return false;
  for (std::size_t i = 0; i < ins.size(); ++i)
    if (e->ins[i].first != ins[i]) return false;
  auto matches = [&](const std::vector<PathHash>& v) {
    for (const auto& [p, h] : v)
      if (!vfs.exists(p) || vfs.hash(p) != h) return false;
    return true;
  };
  return matches(e->ins) && matches(e->deps) && matches(e->outs);
}

}  // namespace kiln
