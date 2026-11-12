/// @file bm25.hpp
/// Okapi BM25 term weighting.
#pragma once

#include <cstddef>

namespace fulltext {

/// BM25 free parameters.
struct Bm25Params {
  double k1 = 1.2;
  double b = 0.75;
};

/// `ln((N - df + 0.5) / (df + 0.5) + 1)`; always positive.
double bm25_idf(std::size_t num_docs, std::size_t df);

/// The contribution of one atom with frequency `f > 0` in a document of
/// length `doc_len`:  `idf * f*(k1+1) / (f + k1*(1 - b + b*doc_len/avgdl))`.
/// When `avgdl` is 0 the ratio `doc_len/avgdl` is taken to be 0.
double bm25_term_score(double idf, double f, double doc_len, double avgdl,
                       const Bm25Params& params = {});

}  // namespace fulltext
