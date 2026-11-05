/**
 * The request/response format used by the command-line tool.
 *
 * A request is one JSON object with a `schema`, a list of `tests` (each with
 * a `data` instance) and an optional `remotes` map of URI to schema document.
 * The response has one line per test: `valid` or `invalid`.
 */
module jsonschema.request;

import std.array : appender;

import jsonschema.json;
import jsonschema.validator;

/// Thrown when a request does not have the expected shape.
class RequestException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

/**
 * Processes a request document and returns the response text.
 *
 * Throws: $(REF JsonException, jsonschema,json) for malformed JSON,
 * `RequestException` for a malformed request, and
 * $(REF SchemaException, jsonschema,compiler) for uncompilable schemas.
 */
string processRequest(string input)
{
    auto doc = parseJson(input);
    if (!doc.isObject)
        throw new RequestException("request must be a JSON object");
    auto schema = "schema" in doc;
    auto tests = "tests" in doc;
    if (schema is null)
        throw new RequestException("missing 'schema'");
    if (tests is null || !tests.isArray)
        throw new RequestException("missing 'tests' array");

    auto validator = new Validator;
    validator.setSchema(*schema);
    if (auto remotes = "remotes" in doc)
    {
        if (remotes.isObject)
            foreach (ref m; remotes.object.members)
                validator.addRemote(m.key, m.value);
    }

    auto output = appender!string();
    foreach (ref t; tests.array)
    {
        auto data = "data" in t;
        if (data is null)
            throw new RequestException("test without 'data'");
        output.put(validator.isValid(*data) ? "valid\n" : "invalid\n");
    }
    return output.data;
}
