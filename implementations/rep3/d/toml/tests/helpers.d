/// Shared helpers for the unit tests.
module tests.helpers;

import toml;

/// Decodes `doc` and returns its tagged JSON, or "error" when it is invalid.
string decode(string doc)
{
    try
        return toTaggedJson(parseToml(doc));
    catch (TomlException)
        return "error";
}

/// True when `doc` is rejected by the parser.
bool rejects(string doc)
{
    try
    {
        parseToml(doc);
        return false;
    }
    catch (TomlException)
        return true;
}

/// JSON text of a single scalar node.
string scalar(string type, string value)
{
    return `{"type":"` ~ type ~ `","value":"` ~ value ~ `"}`;
}
