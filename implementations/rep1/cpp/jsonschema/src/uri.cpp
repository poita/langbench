#include "jsonschema/uri.hpp"

namespace jsonschema::uri {

namespace {

bool is_scheme_char(char c, bool first) {
  if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) return true;
  if (first) return false;
  return (c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.';
}

int hex_value(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

}  // namespace

Reference parse(std::string_view s) {
  Reference r;
  std::size_t i = 0;
  // scheme: letters/digits/+-. followed by ':' before any '/', '?' or '#'.
  std::size_t colon = std::string_view::npos;
  for (std::size_t k = 0; k < s.size(); ++k) {
    char c = s[k];
    if (c == ':') {
      colon = k;
      break;
    }
    if (!is_scheme_char(c, k == 0)) break;
  }
  if (colon != std::string_view::npos && colon > 0) {
    r.scheme = std::string(s.substr(0, colon));
    i = colon + 1;
  }
  if (s.substr(i, 2) == "//") {
    i += 2;
    std::size_t end = s.find_first_of("/?#", i);
    if (end == std::string_view::npos) end = s.size();
    r.authority = std::string(s.substr(i, end - i));
    i = end;
  }
  std::size_t end = s.find_first_of("?#", i);
  if (end == std::string_view::npos) end = s.size();
  r.path = std::string(s.substr(i, end - i));
  i = end;
  if (i < s.size() && s[i] == '?') {
    std::size_t qend = s.find('#', i + 1);
    if (qend == std::string_view::npos) qend = s.size();
    r.query = std::string(s.substr(i + 1, qend - i - 1));
    i = qend;
  }
  if (i < s.size() && s[i] == '#') r.fragment = std::string(s.substr(i + 1));
  return r;
}

std::string recompose(const Reference& r) {
  std::string out;
  if (r.scheme) {
    out += *r.scheme;
    out += ':';
  }
  if (r.authority) {
    out += "//";
    out += *r.authority;
  }
  out += r.path;
  if (r.query) {
    out += '?';
    out += *r.query;
  }
  if (r.fragment) {
    out += '#';
    out += *r.fragment;
  }
  return out;
}

std::string remove_dot_segments(std::string_view in) {
  std::string input(in);
  std::string out;
  auto starts = [&](std::string_view p) { return std::string_view(input).substr(0, p.size()) == p; };
  while (!input.empty()) {
    if (starts("../")) {
      input.erase(0, 3);
    } else if (starts("./")) {
      input.erase(0, 2);
    } else if (starts("/./")) {
      input.erase(0, 2);
    } else if (input == "/.") {
      input = "/";
    } else if (starts("/../") || input == "/..") {
      input.erase(0, 3);
      if (input.empty()) input = "/";
      std::size_t slash = out.rfind('/');
      out.erase(slash == std::string::npos ? 0 : slash);
    } else if (input == "." || input == "..") {
      input.clear();
    } else {
      std::size_t next = input.find('/', input[0] == '/' ? 1 : 0);
      if (next == std::string::npos) next = input.size();
      out.append(input, 0, next);
      input.erase(0, next);
    }
  }
  return out;
}

std::string resolve(std::string_view reference, std::string_view base) {
  Reference r = parse(reference);
  Reference b = parse(base);
  Reference t;
  if (r.scheme) {
    t.scheme = r.scheme;
    t.authority = r.authority;
    t.path = remove_dot_segments(r.path);
    t.query = r.query;
  } else {
    if (r.authority) {
      t.authority = r.authority;
      t.path = remove_dot_segments(r.path);
      t.query = r.query;
    } else {
      if (r.path.empty()) {
        t.path = b.path;
        t.query = r.query ? r.query : b.query;
      } else {
        if (r.path[0] == '/') {
          t.path = remove_dot_segments(r.path);
        } else {
          std::string merged;
          if (b.authority && b.path.empty()) {
            merged = "/" + r.path;
          } else {
            std::size_t slash = b.path.rfind('/');
            merged = (slash == std::string::npos ? std::string() : b.path.substr(0, slash + 1)) + r.path;
          }
          t.path = remove_dot_segments(merged);
        }
        t.query = r.query;
      }
      t.authority = b.authority;
    }
    t.scheme = b.scheme;
  }
  t.fragment = r.fragment;
  return recompose(t);
}

std::string strip_fragment(std::string_view u) {
  std::size_t h = u.find('#');
  return std::string(h == std::string_view::npos ? u : u.substr(0, h));
}

std::pair<std::string, std::optional<std::string>> split_fragment(std::string_view u) {
  std::size_t h = u.find('#');
  if (h == std::string_view::npos) return {std::string(u), std::nullopt};
  return {std::string(u.substr(0, h)), std::string(u.substr(h + 1))};
}

std::string percent_decode(std::string_view s) {
  std::string out;
  out.reserve(s.size());
  for (std::size_t i = 0; i < s.size(); ++i) {
    if (s[i] == '%' && i + 2 < s.size()) {
      int hi = hex_value(s[i + 1]), lo = hex_value(s[i + 2]);
      if (hi >= 0 && lo >= 0) {
        out.push_back(static_cast<char>(hi * 16 + lo));
        i += 2;
        continue;
      }
    }
    out.push_back(s[i]);
  }
  return out;
}

std::optional<std::vector<std::string>> parse_json_pointer(std::string_view p) {
  std::vector<std::string> tokens;
  if (p.empty()) return tokens;
  if (p[0] != '/') return std::nullopt;
  std::size_t i = 1;
  while (true) {
    std::size_t next = p.find('/', i);
    std::string_view raw = p.substr(i, next == std::string_view::npos ? std::string_view::npos : next - i);
    std::string tok;
    for (std::size_t k = 0; k < raw.size(); ++k) {
      if (raw[k] == '~' && k + 1 < raw.size() && raw[k + 1] == '1') {
        tok.push_back('/');
        ++k;
      } else if (raw[k] == '~' && k + 1 < raw.size() && raw[k + 1] == '0') {
        tok.push_back('~');
        ++k;
      } else {
        tok.push_back(raw[k]);
      }
    }
    tokens.push_back(std::move(tok));
    if (next == std::string_view::npos) break;
    i = next + 1;
  }
  return tokens;
}

}  // namespace jsonschema::uri
