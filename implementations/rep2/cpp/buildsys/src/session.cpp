#include "kiln/session.hpp"

#include "kiln/commands.hpp"
#include "kiln/engine.hpp"

namespace kiln {

namespace {

std::vector<std::string> splitWords(std::string_view line) {
  std::vector<std::string> words;
  std::size_t i = 0;
  while (i < line.size()) {
    while (i < line.size() && (line[i] == ' ' || line[i] == '\t')) ++i;
    std::size_t j = i;
    while (j < line.size() && line[j] != ' ' && line[j] != '\t') ++j;
    if (j > i) words.emplace_back(line.substr(i, j - i));
    i = j;
  }
  return words;
}

}  // namespace

std::vector<SessionStep> parseSession(std::string_view script) {
  std::vector<SessionStep> steps;
  std::size_t pos = 0;
  auto nextLine = [&](std::string_view& out) {
    if (pos >= script.size()) return false;
    std::size_t nl = script.find('\n', pos);
    out = script.substr(pos, nl == std::string_view::npos ? script.size() - pos : nl - pos);
    pos = nl == std::string_view::npos ? script.size() : nl + 1;
    return true;
  };
  std::string_view line;
  while (nextLine(line)) {
    std::vector<std::string> words = splitWords(line);
    if (words.empty() || words[0][0] == '#') continue;
    SessionStep st;
    const std::string& cmd = words[0];
    if (cmd == "build") {
      st.kind = SessionStep::Build;
      std::size_t n = words.size();
      std::size_t end = n;
      if (n >= 3 && words[n - 2] == "-j") {
        st.jobs = std::stoi(words[n - 1]);
        end = n - 2;
      }
      for (std::size_t i = 1; i < end; ++i) st.targets.push_back(words[i]);
    } else if (cmd == "create" || cmd == "edit") {
      st.kind = cmd == "create" ? SessionStep::Create : SessionStep::Edit;
      if (words.size() > 1) st.path = words[1];
      std::string_view body;
      while (nextLine(body)) {
        if (body == "---") break;
        st.content.append(body);
        st.content += '\n';
      }
    } else if (cmd == "delete" || cmd == "touch") {
      st.kind = cmd == "delete" ? SessionStep::Delete : SessionStep::Touch;
      if (words.size() > 1) st.path = words[1];
    } else if (cmd == "clean") {
      st.kind = SessionStep::Clean;
    } else {
      continue;  // not a well-formed step; the spec guarantees this never happens
    }
    steps.push_back(std::move(st));
  }
  return steps;
}

std::string runSession(Vfs& vfs, const std::vector<SessionStep>& steps) {
  std::string log;
  int number = 0;
  for (const auto& st : steps) {
    ++number;
    log += "step " + std::to_string(number) + ": ";
    switch (st.kind) {
      case SessionStep::Build: {
        log += "build";
        if (st.targets.empty()) log += " (default)";
        for (const auto& t : st.targets) log += " " + t;
        log += " -j " + std::to_string(st.jobs) + "\n";
        BuildReport rep = runBuild(vfs, st.targets, st.jobs);
        for (const auto& ev : rep.events) {
          switch (ev.kind) {
            case Event::Hit:
              log += "  hit " + std::to_string(ev.start) + " " + ev.target + "\n";
              break;
            case Event::Run:
            case Event::Fail:
            case Event::Cancel: {
              const char* word = ev.kind == Event::Run ? "run" : (ev.kind == Event::Fail ? "fail" : "cancel");
              log += std::string("  ") + word + " " + std::to_string(ev.start) + " " +
                     std::to_string(ev.end) + " w" + std::to_string(ev.worker) + " " + ev.target +
                     " " + ev.command + "\n";
              break;
            }
          }
        }
        if (rep.error) {
          log += "  error " + rep.error->message() + "\n";
        } else {
          log += "  ok ran=" + std::to_string(rep.ran) + " hit=" + std::to_string(rep.hits) +
                 " time=" + std::to_string(rep.time) + "\n";
        }
        break;
      }
      case SessionStep::Create:
      case SessionStep::Edit:
        log += std::string(st.kind == SessionStep::Create ? "create " : "edit ") + st.path + "\n";
        vfs.write(st.path, st.content);
        log += "  ok size=" + std::to_string(st.content.size()) + "\n";
        break;
      case SessionStep::Delete:
        log += "delete " + st.path + "\n";
        vfs.remove(st.path);
        log += "  ok\n";
        break;
      case SessionStep::Touch:
        log += "touch " + st.path + "\n";
        vfs.touch(st.path);
        log += "  ok\n";
        break;
      case SessionStep::Clean: {
        log += "clean\n";
        std::vector<std::string> gone = vfs.generatedPaths();
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

std::string runSession(Vfs& vfs, std::string_view script) {
  return runSession(vfs, parseSession(script));
}

}  // namespace kiln
