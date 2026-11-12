/**
 * A TOML 1.0.0 parser and serializer.
 *
 * The library reads a TOML document into a tree of `Node`s, writes such a tree
 * as canonical TOML, and converts between trees and the toml-test "tagged
 * JSON" format.
 *
 * Example:
 * ---
 * import toml;
 *
 * auto doc = parse(`
 *     title = "Example"
 *     [owner]
 *     name = "Tom"
 *     ports = [8001, 8002]
 * `);
 * assert(doc["title"].asString == "Example");
 * assert(doc["owner"]["ports"][1].asLong == 8002);
 *
 * // Canonical TOML and tagged JSON renderings:
 * string canonical = toToml(doc);
 * string json = toTaggedJson(doc);
 * assert(toToml(fromTaggedJson(json)) == canonical);
 * ---
 */
module toml;

public import toml.datetime;
public import toml.encoder;
public import toml.exception;
public import toml.json;
public import toml.number;
public import toml.parser;
public import toml.value;

/// Decodes a TOML document to compact, key-sorted tagged JSON.
string tomlToTaggedJson(const(char)[] document) @safe
{
    return toTaggedJson(parse(document));
}

/// Encodes a tagged JSON document as canonical TOML.
string taggedJsonToToml(const(char)[] json) @safe
{
    return toToml(fromTaggedJson(json));
}

unittest
{
    auto doc = parse("title = \"Example\"\n[owner]\nname = \"Tom\"\nports = [8001, 8002]\n");
    assert(doc["title"].asString == "Example");
    assert(doc["owner"]["ports"][1].asLong == 8002);
    assert(toToml(fromTaggedJson(toTaggedJson(doc))) == toToml(doc));
}
