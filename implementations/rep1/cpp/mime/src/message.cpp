#include "mime/message.hpp"

#include <functional>

#include "mime/charset.hpp"
#include "mime/checksum.hpp"
#include "mime/header.hpp"
#include "mime/params.hpp"
#include "mime/text.hpp"
#include "mime/transfer.hpp"

namespace mime {
namespace {

bool is_token(std::string_view s) {
  if (s.empty()) return false;
  for (char c : s) {
    switch (c) {
      case ' ': case '\t': case '(': case ')': case '<': case '>': case '@': case ',':
      case ';': case ':': case '\\': case '"': case '/': case '[': case ']': case '?':
      case '=':
        return false;
      default:
        break;
    }
  }
  return true;
}

struct Delimiter {
  std::size_t start;  // first byte of the delimiter line
  std::size_t next;   // first byte after its terminator
  bool close;
};

// Checks whether the line `line` is a delimiter line for `dash_boundary`
// ("--" + boundary).
bool match_delimiter(std::string_view line, std::string_view dash_boundary, bool& close) {
  if (line.size() < dash_boundary.size() || line.compare(0, dash_boundary.size(), dash_boundary) != 0)
    return false;
  std::string_view rest = line.substr(dash_boundary.size());
  close = rest.size() >= 2 && rest[0] == '-' && rest[1] == '-';
  if (close) rest.remove_prefix(2);
  for (char c : rest)
    if (!is_blank(c)) return false;
  return true;
}

// Finds delimiter lines in `body`, stopping after the first close delimiter.
std::vector<Delimiter> find_delimiters(std::string_view body, const std::string& boundary) {
  std::string dash = "--" + boundary;
  std::vector<Delimiter> found;
  std::size_t pos = 0;
  while (pos < body.size()) {
    std::size_t nl = body.find('\n', pos);
    std::size_t end = nl == std::string_view::npos ? body.size() : nl;
    std::size_t next = nl == std::string_view::npos ? body.size() : nl + 1;
    bool close = false;
    if (match_delimiter(body.substr(pos, end - pos), dash, close)) {
      found.push_back({pos, next, close});
      if (close) break;
    }
    pos = next;
  }
  return found;
}

struct Builder {
  int next_index = 0;

  Part parse(std::string_view data, int depth, bool parent_is_digest) {
    Part part;
    part.index = next_index++;
    part.depth = depth;
    HeaderBlock hb = parse_headers(data);
    std::string_view body = data.substr(hb.body_offset);
    part.headers = std::move(hb.fields);

    // Content-Type.
    const HeaderField* ct_field = find_field(part.headers, "content-type");
    StructuredValue ct;
    if (ct_field) ct = parse_structured(ct_field->raw_value);
    std::size_t slash = ct.value.find('/');
    bool usable = false;
    if (ct_field && slash != std::string::npos) {
      std::string_view t = std::string_view(ct.value).substr(0, slash);
      std::string_view s = std::string_view(ct.value).substr(slash + 1);
      if (is_token(t) && is_token(s)) {
        part.type = std::string(t);
        part.subtype = std::string(s);
        usable = true;
      }
    }
    if (!usable) {
      part.type = parent_is_digest ? "message" : "text";
      part.subtype = parent_is_digest ? "rfc822" : "plain";
    }

    // Charset.
    if (part.type == "text") {
      auto cs = ct.param("charset");
      part.charset = cs ? normalize_charset_name(*cs) : "us-ascii";
    }

    // Transfer encoding.
    if (const HeaderField* f = find_field(part.headers, "content-transfer-encoding")) {
      part.cte = ascii_lower(strip_blanks(parse_structured(f->raw_value).value));
    } else {
      part.cte = "7bit";
    }

    // Disposition and filename.
    if (const HeaderField* f = find_field(part.headers, "content-disposition")) {
      StructuredValue cd = parse_structured(f->raw_value);
      part.disposition = cd.value.empty() ? "inline" : cd.value;
      part.filename = cd.param("filename");
    }
    if (!part.filename) part.filename = ct.param("name");

    // Structure.
    auto boundary = ct.param("boundary");
    if (part.type == "multipart" && boundary && !boundary->empty()) {
      part.kind = PartKind::Multipart;
      part.boundary = *boundary;
      parse_multipart(part, body, depth);
    } else if (part.type == "message" && part.subtype == "rfc822") {
      part.kind = PartKind::Message;
      if (is_identity_encoding(part.cte)) {
        part.children.push_back(parse(body, depth + 1, false));
      } else {
        std::string decoded = decode_body(body, part.cte);
        part.children.push_back(parse(decoded, depth + 1, false));
      }
    } else {
      part.kind = PartKind::Leaf;
      part.content = decode_body(body, part.cte);
      part.checksum = adler32(part.content);
    }
    return part;
  }

  void parse_multipart(Part& part, std::string_view body, int depth) {
    std::vector<Delimiter> delims = find_delimiters(body, part.boundary);
    if (delims.empty()) {
      part.preamble_size = body.size();
      return;
    }
    std::size_t pre = delims[0].start;
    if (pre > 0 && body[pre - 1] == '\n') --pre;
    part.preamble_size = pre;
    const bool digest = part.subtype == "digest";
    if (delims[0].close) {
      part.epilogue_size = body.size() - delims[0].next;
      return;
    }
    for (std::size_t k = 0; k < delims.size(); ++k) {
      if (delims[k].close) {
        part.epilogue_size = body.size() - delims[k].next;
        break;
      }
      std::size_t from = delims[k].next;
      std::size_t to = k + 1 < delims.size() ? delims[k + 1].start : body.size();
      if (to > from && body[to - 1] == '\n') --to;
      part.children.push_back(parse(body.substr(from, to - from), depth + 1, digest));
    }
  }
};

// Picks the first text/plain and text/html body candidates. The walk does not
// descend into a message/rfc822 container's child.
void select_bodies(Part& p, Message& m) {
  if (p.kind == PartKind::Message) return;
  if (p.kind == PartKind::Leaf) {
    bool candidate = !p.disposition || *p.disposition != "attachment";
    if (candidate && !m.text_index && p.type == "text" && p.subtype == "plain") {
      m.text_index = p.index;
      p.role = Role::Text;
    } else if (candidate && !m.html_index && p.type == "text" && p.subtype == "html") {
      m.html_index = p.index;
      p.role = Role::Html;
    }
    return;
  }
  for (Part& c : p.children) select_bodies(c, m);
}

void collect_attachments(Part& p, Message& m) {
  if (p.kind == PartKind::Leaf && p.role == Role::None) {
    p.role = Role::Attachment;
    m.attachment_indices.push_back(p.index);
  }
  for (Part& c : p.children) collect_attachments(c, m);
}

}  // namespace

Message parse_message(std::string_view bytes, std::string source_id) {
  Message m;
  m.source_id = std::move(source_id);
  m.byte_length = bytes.size();
  std::string normalized = normalize_newlines(bytes);
  Builder b;
  m.root = b.parse(normalized, 0, false);
  m.part_count = b.next_index;
  select_bodies(m.root, m);
  collect_attachments(m.root, m);
  return m;
}

std::vector<const Part*> flatten(const Message& m) {
  std::vector<const Part*> out;
  std::function<void(const Part&)> walk = [&](const Part& p) {
    out.push_back(&p);
    for (const Part& c : p.children) walk(c);
  };
  walk(m.root);
  return out;
}

std::string part_text(const Part& p) { return decode(p.content, p.charset); }

}  // namespace mime
