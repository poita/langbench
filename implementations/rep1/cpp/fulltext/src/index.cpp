#include "fulltext/index.hpp"

#include <algorithm>

#include "fulltext/analyzer.hpp"

namespace fulltext {

std::span<const std::uint32_t> PostingList::positions(std::size_t i) const noexcept {
  const std::size_t begin = offsets_[i];
  const std::size_t end = i + 1 < offsets_.size() ? offsets_[i + 1] : positions_.size();
  return {positions_.data() + begin, end - begin};
}

std::size_t PostingList::find(DocId d) const noexcept {
  const auto it = std::lower_bound(docs_.begin(), docs_.end(), d);
  return (it != docs_.end() && *it == d) ? static_cast<std::size_t>(it - docs_.begin()) : npos;
}

void PostingList::append(DocId d, std::span<const std::uint32_t> positions) {
  docs_.push_back(d);
  offsets_.push_back(static_cast<std::uint32_t>(positions_.size()));
  positions_.insert(positions_.end(), positions.begin(), positions.end());
}

void PostingList::add_position(DocId d, std::uint32_t position) {
  if (docs_.empty() || docs_.back() != d) {
    docs_.push_back(d);
    offsets_.push_back(static_cast<std::uint32_t>(positions_.size()));
  }
  positions_.push_back(position);
}

Index Index::build(std::vector<Document> documents) {
  std::stable_sort(documents.begin(), documents.end(),
                   [](const Document& a, const Document& b) { return a.id < b.id; });
  Index index;
  index.docs_ = std::move(documents);
  index.lengths_.reserve(index.docs_.size());

  for (std::size_t d = 0; d < index.docs_.size(); ++d) {
    const std::string_view text = index.docs_[d].text;
    const std::vector<Span> spans = tokenize(text);
    for (std::size_t pos = 0; pos < spans.size(); ++pos) {
      std::string term = term_for(fold(text.substr(spans[pos].begin, spans[pos].end - spans[pos].begin)));
      auto it = index.term_ids_.find(term);
      if (it == index.term_ids_.end()) {
        it = index.term_ids_.emplace(std::move(term), static_cast<std::uint32_t>(index.postings_.size())).first;
        index.postings_.emplace_back();
      }
      index.postings_[it->second].add_position(static_cast<DocId>(d), static_cast<std::uint32_t>(pos));
    }
    index.lengths_.push_back(static_cast<std::uint32_t>(spans.size()));
    index.total_tokens_ += spans.size();
  }
  index.avgdl_ = index.docs_.empty()
                     ? 0.0
                     : static_cast<double>(index.total_tokens_) / static_cast<double>(index.docs_.size());
  return index;
}

const PostingList* Index::find(const std::string& term) const {
  const auto it = term_ids_.find(term);
  return it == term_ids_.end() ? nullptr : &postings_[it->second];
}

}  // namespace fulltext
