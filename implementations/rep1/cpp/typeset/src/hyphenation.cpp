#include "typeset/hyphenation.hpp"

#include <algorithm>
#include <fstream>
#include <sstream>
#include <stdexcept>

namespace typeset {

void PatternSet::addPattern(std::string_view text) {
    std::string key;
    std::vector<unsigned char> values(1, 0);
    for (char c : text) {
        if (c >= '0' && c <= '9') {
            values[key.size()] = static_cast<unsigned char>(c - '0');
        } else {
            key.push_back(c);
            values.push_back(0);
        }
    }
    maxKey_ = std::max(maxKey_, key.size());
    patterns_[key] = std::move(values);
}

void PatternSet::addException(std::string_view text) {
    std::string word;
    std::vector<int> pos;
    for (char c : text) {
        if (c == '-') pos.push_back(static_cast<int>(word.size()));
        else word.push_back(c);
    }
    exceptions_[word] = std::move(pos);
}

PatternSet PatternSet::parse(std::string_view text) {
    PatternSet ps;
    std::size_t pos = 0;
    while (pos <= text.size()) {
        std::size_t nl = text.find('\n', pos);
        if (nl == std::string_view::npos) nl = text.size();
        std::string_view line = text.substr(pos, nl - pos);
        pos = nl + 1;
        std::size_t hash = line.find('#');
        if (hash != std::string_view::npos) line = line.substr(0, hash);
        std::size_t b = line.find_first_not_of(" \t");
        if (b == std::string_view::npos) continue;
        std::size_t e = line.find_last_not_of(" \t");
        line = line.substr(b, e - b + 1);
        std::size_t sp = line.find_first_of(" \t");
        std::string_view rec = line.substr(0, sp);
        std::string_view arg;
        if (sp != std::string_view::npos) {
            arg = line.substr(sp);
            arg = arg.substr(arg.find_first_not_of(" \t"));
        }
        if (rec == "left") ps.left = std::stoi(std::string(arg));
        else if (rec == "right") ps.right = std::stoi(std::string(arg));
        else if (rec == "pattern") ps.addPattern(arg);
        else if (rec == "exception") ps.addException(arg);
        else if (rec == "chp") {}
        else throw std::runtime_error("unknown record in pattern file: " + std::string(rec));
    }
    return ps;
}

PatternSet PatternSet::load(const std::string& dataDir, const std::string& name) {
    std::string path = dataDir + "/hyphen/" + name + ".chp";
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("cannot open " + path);
    std::stringstream ss;
    ss << in.rdbuf();
    return parse(ss.str());
}

std::vector<int> PatternSet::breaks(std::string_view word) const {
    const int n = static_cast<int>(word.size());
    std::vector<int> result;
    std::vector<int> candidates;
    auto ex = exceptions_.find(std::string(word));
    if (ex != exceptions_.end()) {
        candidates = ex->second;
    } else {
        std::string t = "." + std::string(word) + ".";
        std::vector<int> v(n + 3, 0);
        const int len = n + 2;
        for (int i = 0; i < len; ++i) {
            std::size_t maxj = std::min<std::size_t>(len, i + maxKey_);
            for (std::size_t j = i + 1; j <= maxj; ++j) {
                auto it = patterns_.find(t.substr(i, j - i));
                if (it == patterns_.end()) continue;
                const auto& pv = it->second;
                for (std::size_t k = 0; k < pv.size(); ++k) v[i + k] = std::max<int>(v[i + k], pv[k]);
            }
        }
        for (int q = 1; q <= n - 1; ++q)
            if (v[1 + q] % 2 == 1) candidates.push_back(q);
    }
    for (int q : candidates)
        if (q >= left && q <= n - right) result.push_back(q);
    return result;
}

}  // namespace typeset
