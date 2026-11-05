/**
 * The public face of the library: compile schemas and validate instances.
 *
 * Example:
 * ---
 * import jsonschema;
 *
 * auto validator = new Validator;
 * validator.setSchema(parseJson(`{"type":"integer","minimum":1}`));
 * assert( validator.isValid(parseJson("3")));
 * assert(!validator.isValid(parseJson("0")));
 * ---
 */
module jsonschema.validator;

import jsonschema.compiler;
import jsonschema.evaluator;
import jsonschema.json;
import jsonschema.node;

/**
 * Validates JSON instances against a JSON Schema draft 2020-12 schema,
 * optionally using a bundle of remote schema documents for references.
 *
 * Not thread-safe: use one `Validator` per thread. Evaluation is recursive,
 * so deeply nested schemas or instances need a large stack (the command-line
 * tool runs on a thread with a 1 GiB stack for this reason).
 */
final class Validator
{
    private SchemaRegistry registry;
    private Evaluator evaluator;
    private Node root;

    this()
    {
        registry = new SchemaRegistry;
        evaluator = new Evaluator(registry);
    }

    /**
     * Registers a remote schema document under the absolute URI `uri`.
     * Documents are never fetched; every reference must resolve to the
     * main schema or to a document added here.
     */
    void addRemote(string uri, Value document)
    {
        registry.addDocument(document, uri);
    }

    /**
     * Sets the schema instances are validated against. Its retrieval URI is
     * `retrievalUri` (empty by default).
     *
     * Throws: $(REF SchemaException, jsonschema,compiler) if the schema contains an
     * invalid regular expression.
     */
    void setSchema(Value schema, string retrievalUri = "")
    {
        root = registry.addDocument(schema, retrievalUri);
    }

    /// True if `instance` is valid against the schema set with $(LREF setSchema).
    bool isValid(const Value instance)
    {
        assert(root !is null, "setSchema must be called before isValid");
        return evaluator.isValid(root, instance);
    }
}
