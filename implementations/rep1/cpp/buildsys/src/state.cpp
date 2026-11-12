#include "kiln/state.hpp"

#include "kiln/hash.hpp"
#include "kiln/path.hpp"

namespace kiln {

namespace {

bool parse_path_hash(std::string_view rest, PathHash& out) {
  std::size_t sp = rest.find(' ');
  if (sp == std::string_view::npos) return false;
  std::string_view path = rest.substr(0, sp);
  std::uint64_t h;
  if (!is_workspace_path(path) || !hash_from_hex(rest.substr(sp + 1), h)) return false;
  out = {std::string(path), h};
  return true;
}

void write_pairs(std::string& out, const char* key, const std::vector<PathHash>& v) {
  for (const auto& [p, h] : v) {
    out += key;
    out += ' ';
    out += p;
    out += ' ';
    out += hash_to_hex(h);
    out += '\n';
  }
}

}  // namespace

BuildState BuildState::parse(std::string_view text) {
  BuildState empty;
  if (text.empty() || text.back() != '\n') return empty;
  std::vector<std::string_view> lines;
  std::size_t pos = 0;
  while (pos < text.size()) {
    std::size_t nl = text.find('\n', pos);
    lines.push_back(text.substr(pos, nl - pos));
    pos = nl + 1;
  }
  if (lines.empty() || lines[0] != "kiln-state 1") return empty;

  BuildState st;
  std::size_t i = 1;
  while (i < lines.size()) {
    std::string_view l = lines[i];
    if (l.substr(0, 5) != "step ") return empty;
    std::string key(l.substr(5));
    if (!is_workspace_path(key)) return empty;
    ++i;
    StateEntry e;
    // exactly one cmd line
    if (i >= lines.size() || lines[i].substr(0, 4) != "cmd " || lines[i].size() == 4) return empty;
    e.command = std::string(lines[i].substr(4));
    ++i;
    PathHash ph;
    while (i < lines.size() && lines[i].substr(0, 3) == "in ") {
      if (!parse_path_hash(lines[i].substr(3), ph)) return empty;
      e.inputs.push_back(ph);
      ++i;
    }
    while (i < lines.size() && lines[i].substr(0, 4) == "dep ") {
      if (!parse_path_hash(lines[i].substr(4), ph)) return empty;
      e.deps.push_back(ph);
      ++i;
    }
    while (i < lines.size() && lines[i].substr(0, 4) == "out ") {
      if (!parse_path_hash(lines[i].substr(4), ph)) return empty;
      e.outputs.push_back(ph);
      ++i;
    }
    if (e.outputs.empty()) return empty;
    if (i >= lines.size() || lines[i] != "end") return empty;
    ++i;
    if (e.outputs.front().first != key) return empty;
    if (!st.entries_.emplace(key, std::move(e)).second) return empty;
  }
  return st;
}

BuildState BuildState::load(const Vfs& vfs) {
  Vfs::Content c = vfs.read(kStateFile);
  return c ? parse(*c) : BuildState();
}

std::string BuildState::serialize() const {
  std::string out = "kiln-state 1\n";
  for (const auto& [key, e] : entries_) {
    out += "step " + key + "\n";
    out += "cmd " + e.command + "\n";
    write_pairs(out, "in", e.inputs);
    write_pairs(out, "dep", e.deps);
    write_pairs(out, "out", e.outputs);
    out += "end\n";
  }
  return out;
}

const StateEntry* BuildState::find(const std::string& key) const {
  auto it = entries_.find(key);
  return it == entries_.end() ? nullptr : &it->second;
}

void BuildState::put(const std::string& key, StateEntry entry) { entries_[key] = std::move(entry); }

void BuildState::erase(const std::string& key) { entries_.erase(key); }

bool is_fresh(const StepDef& step, const BuildState& state, const Vfs& vfs) {
  const StateEntry* e = state.find(step.primary());
  if (!e) return false;
  if (e->command != step.canonical()) return false;

  std::vector<std::string> outs = step.full_outputs();
  if (e->outputs.size() != outs.size()) return false;
  for (std::size_t i = 0; i < outs.size(); ++i) {
    if (e->outputs[i].first != outs[i]) return false;
  }
  std::vector<std::string> ins = step.file_inputs();
  if (e->inputs.size() != ins.size()) return false;
  for (std::size_t i = 0; i < ins.size(); ++i) {
    if (e->inputs[i].first != ins[i]) return false;
  }
  auto unchanged = [&](const std::vector<PathHash>& v) {
    for (const auto& [p, h] : v) {
      if (!vfs.exists(p) || vfs.hash(p) != h) return false;
    }
    return true;
  };
  return unchanged(e->inputs) && unchanged(e->deps) && unchanged(e->outputs);
}

}  // namespace kiln
