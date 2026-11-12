#include "fulltext/bm25.hpp"

#include <cmath>

namespace fulltext {

double bm25_idf(std::size_t num_docs, std::size_t df) {
  const double n = static_cast<double>(num_docs);
  const double d = static_cast<double>(df);
  return std::log((n - d + 0.5) / (d + 0.5) + 1.0);
}

double bm25_term_score(double idf, double f, double doc_len, double avgdl, const Bm25Params& p) {
  const double ratio = avgdl > 0.0 ? doc_len / avgdl : 0.0;
  const double norm = p.k1 * (1.0 - p.b + p.b * ratio);
  return idf * ((f * (p.k1 + 1.0)) / (f + norm));
}

}  // namespace fulltext
