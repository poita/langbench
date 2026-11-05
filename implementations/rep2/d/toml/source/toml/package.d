/**
 * A TOML 1.0.0 parser and serializer.
 *
 * ---
 * import toml;
 *
 * auto doc = parseToml("name = \"Tom\"\n[db]\nports = [8001, 8002]\n");
 * assert(doc["name"].str == "Tom");
 * assert(doc["db"]["ports"][1].integer == 8002);
 *
 * string json = toTaggedJson(doc);   // toml-test tagged JSON
 * string back = toToml(fromTaggedJson(json)); // canonical TOML
 * ---
 *
 * Modules: `toml.decoder` (parsing), `toml.node` (the tree),
 * `toml.jsonwriter` / `toml.jsonreader` (tagged JSON), `toml.encoder`
 * (canonical TOML output), `toml.floatfmt`, `toml.utf8`, `toml.errors`.
 */
module toml;

public import toml.decoder;
public import toml.encoder;
public import toml.errors;
public import toml.jsonreader;
public import toml.jsonwriter;
public import toml.node;
