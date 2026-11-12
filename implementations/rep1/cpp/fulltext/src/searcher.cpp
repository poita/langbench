#include "fulltext/searcher.hpp"

#include <algorithm>

#include "fulltext/analyzer.hpp"
#include "fulltext/matcher.hpp"
#include "fulltext/snippet.hpp"

namespace fulltext {

SearchResult Searcher::search(std::string_view query_text, std::size_t k) const {
  return search(parse_query(query_text), k);
}

SearchResult Searcher::search(const Query& query, std::size_t k) const {
  const Index& index = *index_;
  AtomMatches matches(index);
  const DocSet matched = evaluate(query.root.get(), matches, index.num_docs());

  SearchResult result;
  result.total_matches = matched.size();

  // Score every matched document; cursors walk each atom's posting list in
  // step with the (sorted) matched documents.
  const std::size_t num_atoms = query.positive_atoms.size();
  std::vector<const PostingList*> lists(num_atoms);
  std::vector<double> idf(num_atoms);
  std::vector<std::size_t> cursor(num_atoms, 0);
  for (std::size_t a = 0; a < num_atoms; ++a) {
    lists[a] = &matches.get(query.positive_atoms[a]);
    idf[a] = bm25_idf(index.num_docs(), lists[a]->size());
  }

  struct Scored {
    DocId doc;
    double score;
  };
  std::vector<Scored> scored;
  scored.reserve(matched.size());
  for (const DocId d : matched) {
    double score = 0.0;
    for (std::size_t a = 0; a < num_atoms; ++a) {
      const auto docs = lists[a]->docs();
      const auto it = std::lower_bound(docs.begin() + cursor[a], docs.end(), d);
      cursor[a] = static_cast<std::size_t>(it - docs.begin());
      if (it == docs.end() || *it != d) continue;
      const double f = static_cast<double>(lists[a]->frequency(cursor[a]));
      score += bm25_term_score(idf[a], f, index.length(d), index.avgdl(), params_);
    }
    scored.push_back({d, score});
  }

  const std::size_t keep = std::min(k, scored.size());
  std::partial_sort(scored.begin(), scored.begin() + static_cast<std::ptrdiff_t>(keep), scored.end(),
                    [](const Scored& x, const Scored& y) {
                      return x.score != y.score ? x.score > y.score : x.doc < y.doc;
                    });

  for (std::size_t r = 0; r < keep; ++r) {
    const DocId d = scored[r].doc;
    const Document& doc = index.document(d);
    const std::vector<Span> spans = tokenize(doc.text);

    std::vector<AtomOccurrences> occ;
    for (std::size_t a = 0; a < num_atoms; ++a) {
      const std::size_t i = lists[a]->find(d);
      if (i == PostingList::npos) continue;
      occ.push_back({query.positive_atoms[a].size(), lists[a]->positions(i)});
    }
    const std::size_t start = best_window_start(spans.size(), occ);
    result.hits.push_back({d, doc.id, scored[r].score, render_snippet(doc.text, spans, start)});
  }
  return result;
}

}  // namespace fulltext
