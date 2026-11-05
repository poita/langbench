/**
 * A TOML 1.0.0 parser and canonical serializer.
 *
 * ---
 * import toml;
 *
 * auto doc = parse(`name = "Tom"` ~ "\n[db]\nports = [8001, 8002]\n");
 * assert(doc["name"].asString == "Tom");
 * assert(doc["db"]["ports"][1].asInteger == 8002);
 * writeln(toTaggedJson(doc));   // tagged JSON
 * writeln(toToml(doc));         // canonical TOML
 * ---
 *
 * Modules:
 * $(UL
 *   $(LI `toml.node`    – the document tree ($(D Node), $(D Kind), $(D TomlException)))
 *   $(LI `toml.parser`  – `parse`: TOML text to tree)
 *   $(LI `toml.encoder` – `toToml`: tree to canonical TOML)
 *   $(LI `toml.json`    – `toTaggedJson` / `fromTaggedJson`)
 *   $(LI `toml.scalar`  – number and date-time scanners)
 *   $(LI `toml.validate`– UTF-8 / CR / BOM validation)
 * )
 */
module toml;

public import toml.node;
public import toml.parser : parse;
public import toml.encoder : toToml, renderKey;
public import toml.json : toTaggedJson, fromTaggedJson;

/// Decodes a TOML document straight to tagged JSON.
/// Throws: `TomlException` when the document is invalid.
string tomlToTaggedJson(string document)
{
    return toTaggedJson(parse(document));
}

/// Encodes tagged JSON as canonical TOML.
string taggedJsonToToml(string json)
{
    return toToml(fromTaggedJson(json));
}
