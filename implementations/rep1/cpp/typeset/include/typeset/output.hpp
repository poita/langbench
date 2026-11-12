// Serialisation of the result: layout.txt and report.txt.
#pragma once

#include <string>
#include <vector>

#include "typeset/linebreak.hpp"
#include "typeset/paginate.hpp"
#include "typeset/settings.hpp"

namespace typeset {

/// A finished page: its label and all of its items (header and footer included).
struct OutputPage {
    std::string label;
    std::vector<OutItem> items;
};

/// One item as it appears in layout.txt (without indentation or newline).
std::string formatItem(const OutItem& item);

/// The full text of layout.txt.
std::string formatLayout(const std::vector<OutputPage>& pages, const Settings& settings);

/// The full text of report.txt.
std::string formatReport(const Stats& stats);

}  // namespace typeset
