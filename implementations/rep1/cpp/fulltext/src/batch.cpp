#include "fulltext/batch.hpp"

#include <cstdio>
#include <fstream>
#include <stdexcept>

#include "fulltext/corpus.hpp"
#include "fulltext/utf8.hpp"

namespace fulltext {

namespace {

/// Recognises `%k` <space|tab>+ <digit>+ <space|tab>* and returns k.
bool parse_k_directive(std::string_view line, std::size_t& k) {
  if (line.size() < 2 || line.substr(0, 2) != "%k") return false;
  std::size_t i = 2;
  const auto blank = [&](std::size_t j) { return j < line.size() && (line[j] == ' ' || line[j] == '\t'); };
  if (!blank(i)) return false;
  while (blank(i)) ++i;
  const std::size_t digits = i;
  std::size_t value = 0;
  while (i < line.size() && line[i] >= '0' && line[i] <= '9') {
    if (value < 100000000) value = value * 10 + static_cast<std::size_t>(line[i] - '0');
    ++i;
  }
  if (i == digits) return false;
  while (blank(i)) ++i;
  if (i != line.size()) return false;
  k = value;
  return true;
}

std::string fixed4(double v) {
  char buf[64];
  std::snprintf(buf, sizeof buf, "%.4f", v);
  return buf;
}

}  // namespace

std::vector<QueryEntry> parse_query_file(std::string_view contents) {
  std::vector<QueryEntry> out;
  std::size_t k = kDefaultK;
  std::size_t pos = 0;
  while (pos < contents.size()) {
    std::size_t nl = contents.find('\n', pos);
    if (nl == std::string_view::npos) nl = contents.size();
    const std::string_view line = utf8::strip(contents.substr(pos, nl - pos));
    pos = nl + 1;
    if (line.empty() || line[0] == '#') continue;
    if (std::size_t nk; parse_k_directive(line, nk)) {
      k = nk;
      continue;
    }
    out.push_back({out.size() + 1, std::string(line), k});
  }
  return out;
}

std::string format_results(const Searcher& searcher, const std::vector<QueryEntry>& queries) {
  std::string out;
  for (const QueryEntry& q : queries) {
    const SearchResult r = searcher.search(q.text, q.k);
    out += "QUERY " + std::to_string(q.number) + ' ' + q.text + '\n';
    out += "HITS " + std::to_string(r.hits.size()) + '\n';
    for (std::size_t i = 0; i < r.hits.size(); ++i) {
      const Hit& h = r.hits[i];
      out += std::to_string(i + 1) + '\t' + h.id + '\t' + fixed4(h.score) + '\t' + h.snippet + '\n';
    }
  }
  return out;
}

std::string format_stats(const Index& index) {
  return "documents " + std::to_string(index.num_docs()) + "\ntokens " +
         std::to_string(index.total_tokens()) + "\nterms " + std::to_string(index.num_terms()) +
         "\navgdl " + fixed4(index.avgdl()) + "\n";
}

void run_directory(const std::filesystem::path& input_dir, const std::filesystem::path& output_dir) {
  const std::string queries_text = read_file(input_dir / "queries.txt");
  const Index index = Index::build(load_documents(input_dir));
  const Searcher searcher(index);

  const std::string results = format_results(searcher, parse_query_file(queries_text));
  const std::string stats = format_stats(index);

  std::filesystem::create_directories(output_dir);
  const auto write = [&](const char* name, const std::string& data) {
    std::ofstream f(output_dir / name, std::ios::binary | std::ios::trunc);
    f.write(data.data(), static_cast<std::streamsize>(data.size()));
    if (!f) throw std::runtime_error(std::string("cannot write ") + name);
  };
  write("results.txt", results);
  write("stats.txt", stats);
}

}  // namespace fulltext
