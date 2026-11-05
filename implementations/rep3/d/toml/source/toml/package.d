/**
 * A TOML 1.0.0 parser and serializer.
 *
 * Public API:
 *  - `parseToml` parses a document into a `Node` tree.
 *  - `toTaggedJson` / `fromTaggedJson` convert between a tree and the
 *    "tagged JSON" interchange format of the toml-test suite.
 *  - `toToml` renders a tree as canonical TOML.
 */
module toml;

public import toml.exception;
public import toml.node;
public import toml.parser : parseToml;
public import toml.json : toTaggedJson, fromTaggedJson;
public import toml.encoder : toToml;
