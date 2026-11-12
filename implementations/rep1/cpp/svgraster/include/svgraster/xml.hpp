// A tiny non-validating XML parser sufficient for SVG documents.
#pragma once

#include <map>
#include <memory>
#include <string>
#include <vector>

namespace svgraster {

/// An XML element. Namespace prefixes are stripped from tag and attribute names.
struct Element {
    std::string tag;
    std::map<std::string, std::string> attrs;
    std::vector<std::unique_ptr<Element>> children;

    /// Returns the attribute value, or nullptr when absent.
    const std::string* attr(const std::string& name) const {
        auto it = attrs.find(name);
        return it == attrs.end() ? nullptr : &it->second;
    }
};

/// Parses `text` and returns the document element (the first start tag), or
/// nullptr if the text contains no element.
std::unique_ptr<Element> parse_xml(const std::string& text);

/// Resolves the five predefined entities and numeric character references.
std::string decode_entities(const std::string& s);

}  // namespace svgraster
