#include "jinjalite/engine.hpp"

#include <stdexcept>

#include "jinjalite/json.hpp"

namespace jinjalite {
namespace {

bool starts_with_header(std::string_view s, size_t pos) { return s.substr(pos, 4) == "=== "; }

}  // namespace

Document parse_document(std::string_view input) {
  // The JSON context ends at the first line that is exactly "--".
  size_t pos = 0;
  size_t sep = std::string_view::npos;
  while (pos <= input.size()) {
    size_t eol = input.find('\n', pos);
    size_t end = eol == std::string_view::npos ? input.size() : eol;
    if (input.substr(pos, end - pos) == "--") {
      sep = pos;
      break;
    }
    if (eol == std::string_view::npos) break;
    pos = eol + 1;
  }
  if (sep == std::string_view::npos) throw std::runtime_error("missing '--' separator line");

  Document doc;
  doc.context = parse_json(input.substr(0, sep));
  if (!doc.context.is_dict()) throw std::runtime_error("context must be a JSON object");

  size_t after = input.find('\n', sep);
  after = after == std::string_view::npos ? input.size() : after + 1;

  // Collect header line positions.
  struct Header {
    size_t line_start;
    size_t body_start;
    std::string name;
  };
  std::vector<Header> headers;
  pos = after;
  while (pos < input.size()) {
    size_t eol = input.find('\n', pos);
    size_t end = eol == std::string_view::npos ? input.size() : eol;
    if (starts_with_header(input, pos)) {
      Header h;
      h.line_start = pos;
      h.name = std::string(input.substr(pos + 4, end - pos - 4));
      h.body_start = eol == std::string_view::npos ? input.size() : eol + 1;
      headers.push_back(std::move(h));
    }
    if (eol == std::string_view::npos) break;
    pos = eol + 1;
  }
  if (headers.empty()) throw std::runtime_error("no templates in input");

  for (size_t i = 0; i < headers.size(); ++i) {
    size_t begin = headers[i].body_start;
    size_t finish;
    if (i + 1 < headers.size()) {
      // The LF preceding the next header is not part of the body.
      finish = headers[i + 1].line_start;
      finish = finish > begin ? finish - 1 : begin;
    } else {
      finish = input.size();
      if (finish > begin && input[finish - 1] == '\n') --finish;
    }
    doc.templates.emplace_back(headers[i].name, std::string(input.substr(begin, finish - begin)));
  }
  return doc;
}

std::string render_document(std::string_view input) {
  Document doc = parse_document(input);
  Engine engine;
  engine.set_context(doc.context);
  for (const auto& t : doc.templates) engine.add_template(t.first, t.second);
  return engine.render(doc.templates.front().first);
}

std::string render_document_or_error_line(std::string_view input) {
  try {
    std::string out = render_document(input);
    out += '\n';
    return out;
  } catch (const Error& e) {
    return std::string("error: ") + to_string(e.kind()) + "\n";
  }
}

}  // namespace jinjalite
