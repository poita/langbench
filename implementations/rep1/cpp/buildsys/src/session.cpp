#include "kiln/session.hpp"

#include <algorithm>
#include <stdexcept>

#include "kiln/build.hpp"
#include "kiln/commands.hpp"

namespace kiln {

namespace {

bool is_blank_char(char c) { return c == ' ' || c == '\t'; }

std::string_view strip(std::string_view s) {
  while (!s.empty() && is_blank_char(s.front())) s.remove_prefix(1);
  while (!s.empty() && is_blank_char(s.back())) s.remove_suffix(1);
  return s;
}

std::vector<std::string> split_words(std::string_view s) {
  std::vector<std::string> words;
  std::size_t i = 0;
  while (i < s.size()) {
    while (i < s.size() && is_blank_char(s[i])) ++i;
    std::size_t j = i;
    while (j < s.size() && !is_blank_char(s[j])) ++j;
    if (j > i) words.emplace_back(s.substr(i, j - i));
    i = j;
  }
  return words;
}

std::string event_line(const BuildEvent& e) {
  switch (e.kind) {
    case BuildEvent::Kind::Hit:
      return "  hit " + std::to_string(e.start) + " " + e.target;
    case BuildEvent::Kind::Run:
    case BuildEvent::Kind::Fail:
    case BuildEvent::Kind::Cancel: {
      const char* word = e.kind == BuildEvent::Kind::Run ? "run" : (e.kind == BuildEvent::Kind::Fail ? "fail" : "cancel");
      return std::string("  ") + word + " " + std::to_string(e.start) + " " + std::to_string(e.end) + " w" +
             std::to_string(e.worker) + " " + e.target + " " + e.command;
    }
  }
  return {};
}

}  // namespace

std::vector<SessionStep> parse_session(std::string_view script) {
  std::vector<std::string_view> lines;
  std::size_t pos = 0;
  while (pos < script.size()) {
    std::size_t nl = script.find('\n', pos);
    lines.push_back(script.substr(pos, nl == std::string_view::npos ? nl : nl - pos));
    if (nl == std::string_view::npos) break;
    pos = nl + 1;
  }

  std::vector<SessionStep> steps;
  for (std::size_t i = 0; i < lines.size(); ++i) {
    std::string_view line = strip(lines[i]);
    if (line.empty() || line.front() == '#') continue;
    std::vector<std::string> words = split_words(line);
    SessionStep step;
    const std::string& cmd = words[0];
    if (cmd == "build") {
      step.kind = SessionStep::Kind::Build;
      std::size_t end = words.size();
      if (words.size() >= 3 && words[words.size() - 2] == "-j") {
        step.workers = std::stoi(words.back());
        end = words.size() - 2;
      }
      step.targets.assign(words.begin() + 1, words.begin() + static_cast<std::ptrdiff_t>(end));
    } else if (cmd == "create" || cmd == "edit") {
      if (words.size() != 2) throw std::runtime_error("bad session line: " + std::string(line));
      step.kind = cmd == "create" ? SessionStep::Kind::Create : SessionStep::Kind::Edit;
      step.path = words[1];
      bool closed = false;
      for (++i; i < lines.size(); ++i) {
        if (lines[i] == "---") {
          closed = true;
          break;
        }
        step.content.append(lines[i]);
        step.content += '\n';
      }
      if (!closed) throw std::runtime_error("unterminated content block for " + step.path);
    } else if (cmd == "delete" || cmd == "touch") {
      if (words.size() != 2) throw std::runtime_error("bad session line: " + std::string(line));
      step.kind = cmd == "delete" ? SessionStep::Kind::Delete : SessionStep::Kind::Touch;
      step.path = words[1];
    } else if (cmd == "clean") {
      step.kind = SessionStep::Kind::Clean;
    } else {
      throw std::runtime_error("unknown session step: " + std::string(line));
    }
    steps.push_back(std::move(step));
  }
  return steps;
}

std::string run_session(Vfs& vfs, const std::vector<SessionStep>& steps) {
  std::string log;
  int n = 0;
  for (const SessionStep& s : steps) {
    ++n;
    std::string head = "step " + std::to_string(n) + ": ";
    switch (s.kind) {
      case SessionStep::Kind::Build: {
        head += "build";
        if (s.targets.empty()) {
          head += " (default)";
        } else {
          for (const auto& t : s.targets) head += " " + t;
        }
        head += " -j " + std::to_string(s.workers);
        log += head + "\n";
        BuildOptions opts;
        opts.targets = s.targets;
        opts.workers = s.workers;
        BuildReport r = run_build(vfs, opts);
        for (const auto& e : r.events) log += event_line(e) + "\n";
        if (r.error) {
          log += "  error " + r.error->text() + "\n";
        } else {
          log += "  ok ran=" + std::to_string(r.ran) + " hit=" + std::to_string(r.hits) +
                 " time=" + std::to_string(r.time) + "\n";
        }
        break;
      }
      case SessionStep::Kind::Create:
      case SessionStep::Kind::Edit:
        log += head + (s.kind == SessionStep::Kind::Create ? "create " : "edit ") + s.path + "\n";
        vfs.write(s.path, s.content);
        log += "  ok size=" + std::to_string(s.content.size()) + "\n";
        break;
      case SessionStep::Kind::Delete:
        log += head + "delete " + s.path + "\n";
        vfs.remove(s.path);
        log += "  ok\n";
        break;
      case SessionStep::Kind::Touch:
        log += head + "touch " + s.path + "\n";
        vfs.touch(s.path);
        log += "  ok\n";
        break;
      case SessionStep::Kind::Clean: {
        log += head + "clean\n";
        std::vector<std::string> gone = vfs.generated_paths();
        for (const auto& p : gone) {
          log += "  remove " + p + "\n";
          vfs.remove(p);
        }
        log += "  ok removed=" + std::to_string(gone.size()) + "\n";
        break;
      }
    }
  }
  return log;
}

std::string run_session(Vfs& vfs, std::string_view script) {
  return run_session(vfs, parse_session(script));
}

}  // namespace kiln
