// The public entry point of the typesetting library.
//
//   typeset::Input in;
//   in.document = "Hello, world.\n";
//   typeset::Result r = typeset::run(in, "data");
//   // r.layout / r.report on success, r.error otherwise
#pragma once

#include <optional>
#include <string>

#include "typeset/document.hpp"
#include "typeset/error.hpp"
#include "typeset/font.hpp"
#include "typeset/hlist.hpp"
#include "typeset/hyphenation.hpp"
#include "typeset/layout.hpp"
#include "typeset/linebreak.hpp"
#include "typeset/output.hpp"
#include "typeset/paginate.hpp"
#include "typeset/settings.hpp"

namespace typeset {

/// The contents of the input directory.
struct Input {
    std::optional<std::string> document;  ///< `document.cdx`; absent => `missing-document`
    std::optional<std::string> settings;  ///< `settings.cfg`; absent => all defaults
};

/// Either the two output files or the one error line.
struct Result {
    bool ok = false;
    std::string layout;  ///< contents of layout.txt (when ok)
    std::string report;  ///< contents of report.txt (when ok)
    std::string error;   ///< contents of error.txt, with trailing newline (when !ok)
    Stats stats;
};

/// Typeset a document. `dataDir` holds `faces/*.cfm` and `hyphen/*.chp`.
/// Invalid input is reported in `Result::error`; missing or malformed data
/// files throw `std::runtime_error`.
Result run(const Input& input, const std::string& dataDir);

/// Pre-loaded resources, for callers that typeset many documents.
struct Resources {
    FontSet fonts;
    PatternSet english, minimal;
    static Resources load(const std::string& dataDir);
};

/// Like `run`, with resources loaded once by the caller.
Result run(const Input& input, const Resources& resources);

}  // namespace typeset
