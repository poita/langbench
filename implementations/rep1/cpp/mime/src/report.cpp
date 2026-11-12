#include "mime/report.hpp"

#include <fstream>
#include <stdexcept>

#include "mime/address.hpp"
#include "mime/charset.hpp"
#include "mime/checksum.hpp"
#include "mime/date.hpp"
#include "mime/header.hpp"
#include "mime/mailbox.hpp"
#include "mime/text.hpp"

namespace mime {
namespace fs = std::filesystem;

namespace {

std::string index_or_dash(const std::optional<int>& i) { return i ? std::to_string(*i) : "-"; }

std::string type_of(const Part& p) { return p.type + "/" + p.subtype; }

void write_file(const fs::path& path, const std::string& data) {
  std::ofstream out(path, std::ios::binary);
  out.write(data.data(), static_cast<std::streamsize>(data.size()));
  if (!out) throw std::runtime_error("cannot write " + path.string());
}

void render_addresses(const Message& m, std::string& out) {
  static const char* const names[] = {"from", "sender", "reply-to", "to", "cc", "bcc"};
  for (const char* name : names) {
    int k = 0;
    for (const HeaderField& f : m.root.headers) {
      if (f.key() != name) continue;
      for (const Address& a : parse_address_list(f.raw_value)) {
        out += std::string(name) + " " + std::to_string(k++) + " display=" + quote(a.display) +
               " spec=" + quote(a.spec) + "\n";
      }
    }
  }
}

void render_date(const Message& m, std::string& out) {
  const HeaderField* f = find_field(m.root.headers, "date");
  if (!f) {
    out += "none\n";
    return;
  }
  out += "raw " + quote(f->raw_value) + "\n";
  if (auto d = parse_date(f->raw_value)) {
    out += "valid yes\nutc " + d->utc + "\noffset " + d->offset + "\nepoch " +
           std::to_string(d->epoch) + "\n";
  } else {
    out += "valid no\n";
  }
}

void render_structure(const Part& p, std::string& out) {
  out.append(static_cast<std::size_t>(p.depth) * 2, ' ');
  out += std::to_string(p.index) + " " + type_of(p);
  if (p.is_text()) out += " charset=" + p.charset;
  out += " cte=" + p.cte;
  if (p.disposition) out += " disposition=" + *p.disposition;
  if (p.filename) out += " filename=" + quote(*p.filename);
  if (p.kind == PartKind::Multipart) out += " boundary=" + quote(p.boundary);
  if (p.is_container()) out += " parts=" + std::to_string(p.children.size());
  if (p.kind == PartKind::Multipart) {
    out += " preamble=" + std::to_string(p.preamble_size);
    out += " epilogue=" + (p.epilogue_size ? std::to_string(*p.epilogue_size) : std::string("none"));
  }
  if (p.kind == PartKind::Leaf) {
    out += " size=" + std::to_string(p.content.size());
    out += " adler32=" + adler32_hex(p.content);
    out += p.role == Role::Text ? " role=text" : p.role == Role::Html ? " role=html" : " role=attachment";
  }
  out += "\n";
  for (const Part& c : p.children) render_structure(c, out);
}

void render_body(const char* label, const std::optional<int>& index,
                 const std::vector<const Part*>& parts, std::string& out) {
  if (!index) {
    out += std::string(label) + " none\n";
    return;
  }
  std::string text = part_text(*parts[static_cast<std::size_t>(*index)]);
  out += std::string(label) + " " + std::to_string(*index) + " chars " +
         std::to_string(count_code_points(text)) + "\n";
  std::size_t pos = 0;
  while (pos < text.size()) {
    std::size_t nl = text.find('\n', pos);
    std::size_t end = nl == std::string::npos ? text.size() : nl;
    out += "| " + escape(std::string_view(text).substr(pos, end - pos)) + "\n";
    pos = nl == std::string::npos ? text.size() : nl + 1;
  }
}

}  // namespace

std::string format_number(int n, int width) {
  std::string s = std::to_string(n);
  if (static_cast<int>(s.size()) < width) s.insert(0, static_cast<std::size_t>(width) - s.size(), '0');
  return s;
}

std::string attachment_path(int message_number, int part_index) {
  return "parts/" + format_number(message_number, 4) + "/" + format_number(part_index, 3) + ".bin";
}

std::string render_message(const Message& m, int number) {
  std::string out;
  std::vector<const Part*> parts = flatten(m);

  out += "[message]\nid " + format_number(number, 4) + "\nsource " + quote(m.source_id) + "\n\n";

  out += "[headers]\n";
  for (const HeaderField& f : m.root.headers) out += f.key() + ": " + quote(display_value(f)) + "\n";
  out += "\n[addresses]\n";
  render_addresses(m, out);
  out += "\n[date]\n";
  render_date(m, out);
  out += "\n[structure]\n";
  render_structure(m.root, out);
  out += "\n[body]\n";
  render_body("text", m.text_index, parts, out);
  render_body("html", m.html_index, parts, out);
  out += "\n[attachments]\n";
  for (int idx : m.attachment_indices) {
    const Part& p = *parts[static_cast<std::size_t>(idx)];
    out += std::to_string(idx) + " type=" + type_of(p) + " filename=" +
           (p.filename ? quote(*p.filename) : std::string("-")) +
           " size=" + std::to_string(p.content.size()) + " adler32=" + adler32_hex(p.content) +
           " file=" + attachment_path(number, idx) + "\n";
  }
  return out;
}

std::string render_summary(const std::vector<Message>& messages) {
  std::string out = "messages " + std::to_string(messages.size()) + "\n";
  int n = 0;
  for (const Message& m : messages) {
    out += format_number(++n, 4) + " source=" + quote(m.source_id) +
           " bytes=" + std::to_string(m.byte_length) + " parts=" + std::to_string(m.part_count) +
           " attachments=" + std::to_string(m.attachment_indices.size()) +
           " text=" + index_or_dash(m.text_index) + " html=" + index_or_dash(m.html_index) + "\n";
  }
  return out;
}

void write_output(const std::vector<Message>& messages, const fs::path& out_dir) {
  fs::create_directories(out_dir / "messages");
  write_file(out_dir / "summary.txt", render_summary(messages));
  int n = 0;
  for (const Message& m : messages) {
    ++n;
    write_file(out_dir / "messages" / (format_number(n, 4) + ".txt"), render_message(m, n));
    if (m.attachment_indices.empty()) continue;
    fs::create_directories(out_dir / "parts" / format_number(n, 4));
    std::vector<const Part*> parts = flatten(m);
    for (int idx : m.attachment_indices)
      write_file(out_dir / attachment_path(n, idx), parts[static_cast<std::size_t>(idx)]->content);
  }
}

void process_mailbox(const fs::path& input, const fs::path& out_dir) {
  std::vector<Message> messages;
  for (RawMessage& raw : read_mailbox(input))
    messages.push_back(parse_message(raw.bytes, std::move(raw.source_id)));
  write_output(messages, out_dir);
}

}  // namespace mime
