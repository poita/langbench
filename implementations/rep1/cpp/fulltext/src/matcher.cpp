#include "fulltext/matcher.hpp"

#include <algorithm>
#include <numeric>

namespace fulltext {

PostingList match_atom(const Index& index, const Atom& atom) {
  PostingList result;
  if (atom.empty()) return result;

  std::vector<const PostingList*> lists;
  lists.reserve(atom.size());
  for (const std::string& term : atom) {
    const PostingList* pl = index.find(term);
    if (pl == nullptr) return result;
    lists.push_back(pl);
  }

  if (lists.size() == 1) {
    const PostingList& pl = *lists[0];
    for (std::size_t i = 0; i < pl.size(); ++i) result.append(pl.doc(i), pl.positions(i));
    return result;
  }

  // Documents containing all terms: walk the first list and advance a cursor
  // in each other list.
  std::vector<std::size_t> cursor(lists.size(), 0);
  std::vector<std::uint32_t> candidates;
  for (std::size_t i = 0; i < lists[0]->size(); ++i) {
    const DocId d = lists[0]->doc(i);
    std::vector<std::size_t> at(lists.size(), 0);
    at[0] = i;
    bool in_all = true;
    for (std::size_t t = 1; t < lists.size(); ++t) {
      const auto docs = lists[t]->docs();
      const auto it = std::lower_bound(docs.begin() + cursor[t], docs.end(), d);
      cursor[t] = static_cast<std::size_t>(it - docs.begin());
      if (it == docs.end()) return result;  // no later document can match
      if (*it != d) {
        in_all = false;
        break;
      }
      at[t] = cursor[t];
    }
    if (!in_all) continue;

    // Start positions: positions of term 0, filtered by term t at p + t.
    const auto first = lists[0]->positions(i);
    candidates.assign(first.begin(), first.end());
    for (std::size_t t = 1; t < lists.size() && !candidates.empty(); ++t) {
      const auto pos = lists[t]->positions(at[t]);
      std::size_t q = 0, out = 0;
      for (const std::uint32_t c : candidates) {
        const std::uint32_t want = c + static_cast<std::uint32_t>(t);
        while (q < pos.size() && pos[q] < want) ++q;
        if (q == pos.size()) break;
        if (pos[q] == want) candidates[out++] = c;
      }
      candidates.resize(out);
    }
    if (!candidates.empty()) result.append(d, candidates);
  }
  return result;
}

const PostingList& AtomMatches::get(const Atom& atom) {
  auto it = cache_.find(atom);
  if (it == cache_.end()) it = cache_.emplace(atom, match_atom(*index_, atom)).first;
  return it->second;
}

DocSet evaluate(const QueryNode* node, AtomMatches& matches, std::size_t num_docs) {
  if (node == nullptr) return {};
  switch (node->kind) {
    case QueryNode::Kind::Atom: {
      const auto docs = matches.get(node->atom).docs();
      return DocSet(docs.begin(), docs.end());
    }
    case QueryNode::Kind::Not: {
      const DocSet inner = evaluate(node->children[0].get(), matches, num_docs);
      DocSet all(num_docs);
      std::iota(all.begin(), all.end(), DocId{0});
      DocSet out;
      std::set_difference(all.begin(), all.end(), inner.begin(), inner.end(), std::back_inserter(out));
      return out;
    }
    case QueryNode::Kind::And:
    case QueryNode::Kind::Or: {
      DocSet acc = evaluate(node->children[0].get(), matches, num_docs);
      for (std::size_t i = 1; i < node->children.size(); ++i) {
        const DocSet next = evaluate(node->children[i].get(), matches, num_docs);
        DocSet merged;
        if (node->kind == QueryNode::Kind::And) {
          std::set_intersection(acc.begin(), acc.end(), next.begin(), next.end(),
                                std::back_inserter(merged));
        } else {
          std::set_union(acc.begin(), acc.end(), next.begin(), next.end(), std::back_inserter(merged));
        }
        acc = std::move(merged);
      }
      return acc;
    }
  }
  return {};
}

}  // namespace fulltext
