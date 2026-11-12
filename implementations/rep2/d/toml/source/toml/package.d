/**
 * A TOML 1.0.0 parser and serializer.
 *
 * ---
 * import toml;
 *
 * auto doc = parseToml(`name = "Tom"
 * [db]
 * ports = [8001, 8002]`);
 * assert(doc["name"].text == "Tom");
 * assert(doc["db"]["ports"].items.length == 2);
 * writeln(toTaggedJson(doc));   // the toml-test tagged-JSON form
 * writeln(toToml(doc));         // canonical TOML
 * ---
 *
 * Modules:
 * $(UL
 *   $(LI `toml.node`     - the document tree (`Node`) and `TomlException`)
 *   $(LI `toml.decoder`  - `parseToml`)
 *   $(LI `toml.encoder`  - `toToml`)
 *   $(LI `toml.json`     - `toTaggedJson` / `fromTaggedJson`)
 *   $(LI `toml.convert`  - whole-document helpers used by the CLI)
 *   $(LI `toml.datetime`, `toml.numbers`, `toml.utf8` - scalar helpers)
 * )
 */
module toml;

public import toml.convert;
public import toml.datetime;
public import toml.decoder;
public import toml.encoder;
public import toml.json;
public import toml.node;
public import toml.numbers;
public import toml.utf8;

unittest
{
    auto doc = parseToml("name = \"Tom\"\n[db]\nports = [8001, 8002]\n");
    assert(doc["name"].text == "Tom");
    assert(doc["db"]["ports"].items.length == 2);
    assert(toToml(doc) == "name = \"Tom\"\n\n[db]\nports = [8001, 8002]\n");
}
