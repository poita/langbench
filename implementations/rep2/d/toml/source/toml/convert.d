/**
 * Whole-document conversions: the two operations behind the command-line tool.
 */
module toml.convert;

import toml.decoder : parseToml;
import toml.encoder : toToml;
import toml.json : fromTaggedJson, toTaggedJson;
import toml.node : TomlException;


/**
 * Decodes a TOML document to tagged JSON.
 *
 * Returns: the compact, key-sorted tagged JSON
 * Throws: `TomlException` if `document` is not valid TOML 1.0.0
 */
string tomlToTaggedJson(const(ubyte)[] document)
{
    return toTaggedJson(parseToml(document));
}

/**
 * Encodes tagged JSON as a canonical TOML document.
 *
 * Throws: `TomlException` if `json` is not well-formed tagged JSON
 */
string taggedJsonToToml(string json)
{
    return toToml(fromTaggedJson(json));
}

/**
 * Handles one command-line request: a first line naming the mode (`decode` or
 * `encode`) followed by the document.
 *
 * Params:
 *     input = the whole of standard input
 *     diagnostic = receives a message when the request fails
 * Returns: the text to print, always ending in a newline. A TOML document that
 * fails to decode yields `error`.
 */
string processRequest(const(ubyte)[] input, out string diagnostic)
{
    size_t nl = 0;
    while (nl < input.length && input[nl] != '\n')
        nl++;
    const(char)[] mode = cast(const(char)[]) input[0 .. nl];
    const(ubyte)[] document = nl < input.length ? input[nl + 1 .. $] : null;

    try
    {
        if (mode == "decode")
            return tomlToTaggedJson(document) ~ "\n";
        if (mode == "encode")
            return taggedJsonToToml(cast(string) document.idup);
        diagnostic = "unknown mode";
        return "error\n";
    }
    catch (Exception e)
    {
        diagnostic = e.msg;
        return mode == "decode" ? "error\n" : "\n";
    }
}

unittest
{
    string diag;
    auto bytes = (string s) => cast(const(ubyte)[]) s;
    assert(processRequest(bytes("decode\na = 1\n"), diag) ==
        "{\"a\":{\"type\":\"integer\",\"value\":\"1\"}}\n" && diag.length == 0);
    assert(processRequest(bytes("decode\na = \n"), diag) == "error\n" && diag.length);
    assert(processRequest(bytes("decode\n"), diag) == "{}\n");
    assert(processRequest(bytes("decode\n\xff"), diag) == "error\n");
    assert(processRequest(bytes("encode\n{}"), diag) == "\n");
    assert(processRequest(bytes("encode\n{\"a\":{\"type\":\"bool\",\"value\":\"true\"}}"), diag)
        == "a = true\n");
    assert(processRequest(bytes("bogus\n"), diag) == "error\n");
}

unittest
{
    immutable json = tomlToTaggedJson(cast(const(ubyte)[]) "a = 1.5\n[t]\nb = 'x'\n");
    assert(json == `{"a":{"type":"float","value":"1.5000000000000000e+00"},`
        ~ `"t":{"b":{"type":"string","value":"x"}}}`);
    assert(taggedJsonToToml(json) == "a = 1.5000000000000000e+00\n\n[t]\nb = \"x\"\n");
}
