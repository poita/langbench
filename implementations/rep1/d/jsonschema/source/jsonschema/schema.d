/**
 * Compiled schemas and the schema registry.
 *
 * `Registry.add` walks a document once (JSON Schema 2020-12 section 6.2),
 * decoding every schema object into a `Schema` node, and indexes resources
 * (`$id`), anchors and dynamic anchors. References are resolved lazily, once,
 * by `Registry.resolveRef` / `Registry.dynamicTarget`.
 */
module jsonschema.schema;

import std.typecons : Nullable;

import jsonschema.json;
import jsonschema.number;
import jsonschema.regex;
import jsonschema.uri;

/// Thrown when a reference cannot be resolved.
class SchemaException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

/// Bit set of JSON types accepted by `type`.
enum TypeBits : uint
{
    null_ = 1,
    boolean = 2,
    object = 4,
    array = 8,
    number = 16,
    string = 32,
    integer = 64,
}

/// An entry of `patternProperties`.
struct PatternEntry
{
    string pattern;
    Schema schema;
}

/// A reference keyword (`$ref` / `$dynamicRef`) with its lazily resolved target.
struct RefInfo
{
    string text; /// the reference as written
    bool present;
    bool resolved;
    Schema target; /// resolved static target
    int docBase = -1; /// base id of the document part (for `$dynamicRef`)
    string anchorName; /// plain-name fragment, when any
}

/// One compiled schema object (or boolean schema).
final class Schema
{
    bool isBool; /// a boolean schema
    bool boolValue; /// its value
    int baseId; /// interned base URI in force for this schema object
    string baseUri;
    JsonValue raw;

    // any type
    uint typeMask; /// 0 when `type` is absent
    JsonValue[] enumValues;
    bool hasEnum;
    JsonValue constValue; /// null reference when absent

    // numbers
    Nullable!Number multipleOf, maximum, minimum, exclusiveMaximum, exclusiveMinimum;

    // strings
    long maxLength = -1, minLength = -1;
    string pattern;
    bool hasPattern;

    // arrays
    long maxItems = -1, minItems = -1;
    bool uniqueItems;
    Schema[] prefixItems;
    bool hasPrefixItems;
    Schema items, contains, unevaluatedItems;
    long minContains = -1, maxContains = -1;

    // objects
    long maxProperties = -1, minProperties = -1;
    string[] required;
    string[] dependentRequiredNames;
    string[][] dependentRequiredLists;
    Schema[string] properties;
    PatternEntry[] patternProperties;
    Schema additionalProperties, propertyNames, unevaluatedProperties;
    string[] dependentSchemaNames;
    Schema[] dependentSchemas;

    // in-place applicators
    Schema[] allOf, anyOf, oneOf;
    Schema not, ifSchema, thenSchema, elseSchema;

    // references
    RefInfo ref_, dynamicRef;

    /// True when this object has `unevaluatedItems` or `unevaluatedProperties`.
    bool hasUnevaluated()
    {
        return unevaluatedItems !is null || unevaluatedProperties !is null;
    }
}

/// Holds every compiled document and answers reference lookups.
final class Registry
{
    /// Cache of compiled regular expressions shared by all schemas.
    RegexCache regexes;

    private int[string] baseIds;
    private string[] baseNames;
    private Schema[string] resources; // base URI -> resource root
    private JsonValue[string] resourceRaw;
    private Schema[string] anchors; // base#name
    private Schema[string] dynAnchors; // base#name
    private Schema[int][string] dynByName; // name -> baseId -> schema
    private Schema[JsonValue] nodes;

    /// Creates an empty registry.
    this()
    {
        regexes = new RegexCache;
    }

    /// Interns a base URI.
    int intern(string uri)
    {
        if (auto p = uri in baseIds)
            return *p;
        immutable id = cast(int) baseNames.length;
        baseNames ~= uri;
        baseIds[uri] = id;
        return id;
    }

    /// The text of an interned base URI.
    string baseName(int id) const
    {
        return baseNames[id];
    }

    /// Compiles and indexes a document whose retrieval URI is `retrievalUri`.
    /// Returns the root schema.
    Schema add(JsonValue doc, string retrievalUri)
    {
        auto root = compile(doc, retrievalUri);
        if (!(retrievalUri in resources))
        {
            resources[retrievalUri] = root;
            resourceRaw[retrievalUri] = doc;
            intern(retrievalUri);
        }
        return root;
    }

    // ---- compilation --------------------------------------------------

    private Schema compile(JsonValue v, string base)
    {
        if (auto p = v in nodes)
            return *p;
        auto s = new Schema;
        s.raw = v;
        nodes[v] = s;
        if (v.type == JsonType.boolean)
        {
            s.isBool = true;
            s.boolValue = v.boolean;
            s.baseUri = base;
            s.baseId = intern(base);
            return s;
        }
        if (!v.isObject)
        {
            // Not a schema position holding a schema: treat as `true`.
            s.isBool = true;
            s.boolValue = true;
            s.baseUri = base;
            s.baseId = intern(base);
            return s;
        }
        if (auto idv = v.get("$id"))
        {
            if (idv.isString)
                base = resolveString(base, idv.str).withoutFragment().toString();
            if (idv.isString)
            {
                if (!(base in resources))
                {
                    resources[base] = s;
                    resourceRaw[base] = v;
                }
            }
        }
        s.baseUri = base;
        s.baseId = intern(base);
        if (auto a = v.get("$anchor"))
            if (a.isString)
                anchors[base ~ "#" ~ a.str] = s;
        if (auto a = v.get("$dynamicAnchor"))
            if (a.isString)
            {
                immutable key = base ~ "#" ~ a.str;
                if (!(key in dynAnchors))
                    dynAnchors[key] = s;
                dynByName[a.str][s.baseId] = s;
            }
        decode(s, v, base);
        return s;
    }

    private Schema sub(JsonValue v, string base)
    {
        return compile(v, base);
    }

    private static long countOf(JsonValue v)
    {
        if (v is null || !v.isNumber)
            return -1;
        return v.number.toCount();
    }

    private static string[] stringList(JsonValue v)
    {
        string[] r;
        if (v is null || !v.isArray)
            return r;
        foreach (x; v.items)
            if (x.isString)
                r ~= x.str;
        return r;
    }

    private Schema[] schemaList(JsonValue v, string base)
    {
        Schema[] r;
        if (v is null || !v.isArray)
            return r;
        foreach (x; v.items)
            r ~= sub(x, base);
        return r;
    }

    private void decode(Schema s, JsonValue v, string base)
    {
        // any type
        if (auto t = v.get("type"))
        {
            if (t.isString)
                s.typeMask = typeBit(t.str);
            else if (t.isArray)
                foreach (x; t.items)
                    if (x.isString)
                        s.typeMask |= typeBit(x.str);
            if (s.typeMask == 0)
                s.typeMask = 0x80000000; // present but matches nothing
        }
        if (auto e = v.get("enum"))
            if (e.isArray)
            {
                s.hasEnum = true;
                s.enumValues = e.items;
            }
        s.constValue = v.get("const");

        // numbers
        void num(string name, ref Nullable!Number dst)
        {
            if (auto x = v.get(name))
                if (x.isNumber)
                    dst = x.number;
        }

        num("multipleOf", s.multipleOf);
        num("maximum", s.maximum);
        num("minimum", s.minimum);
        num("exclusiveMaximum", s.exclusiveMaximum);
        num("exclusiveMinimum", s.exclusiveMinimum);
        if (!s.multipleOf.isNull && s.multipleOf.get.sign() <= 0)
            s.multipleOf.nullify();

        // strings
        s.maxLength = countOf(v.get("maxLength"));
        s.minLength = countOf(v.get("minLength"));
        if (auto p = v.get("pattern"))
            if (p.isString)
            {
                s.hasPattern = true;
                s.pattern = p.str;
            }

        // arrays
        s.maxItems = countOf(v.get("maxItems"));
        s.minItems = countOf(v.get("minItems"));
        if (auto u = v.get("uniqueItems"))
            s.uniqueItems = u.type == JsonType.boolean && u.boolean;
        if (auto p = v.get("prefixItems"))
            if (p.isArray)
            {
                s.hasPrefixItems = true;
                s.prefixItems = schemaList(p, base);
            }
        if (auto x = v.get("items"))
            s.items = sub(x, base);
        if (auto x = v.get("contains"))
            s.contains = sub(x, base);
        if (auto x = v.get("unevaluatedItems"))
            s.unevaluatedItems = sub(x, base);
        s.minContains = countOf(v.get("minContains"));
        s.maxContains = countOf(v.get("maxContains"));

        // objects
        s.maxProperties = countOf(v.get("maxProperties"));
        s.minProperties = countOf(v.get("minProperties"));
        s.required = stringList(v.get("required"));
        if (auto d = v.get("dependentRequired"))
            if (d.isObject)
                foreach (i, k; d.keys)
                {
                    s.dependentRequiredNames ~= k;
                    s.dependentRequiredLists ~= stringList(d.values[i]);
                }
        if (auto p = v.get("properties"))
            if (p.isObject)
                foreach (i, k; p.keys)
                    s.properties[k] = sub(p.values[i], base);
        if (auto p = v.get("patternProperties"))
            if (p.isObject)
                foreach (i, k; p.keys)
                    s.patternProperties ~= PatternEntry(k, sub(p.values[i], base));
        if (auto x = v.get("additionalProperties"))
            s.additionalProperties = sub(x, base);
        if (auto x = v.get("propertyNames"))
            s.propertyNames = sub(x, base);
        if (auto x = v.get("unevaluatedProperties"))
            s.unevaluatedProperties = sub(x, base);
        if (auto d = v.get("dependentSchemas"))
            if (d.isObject)
                foreach (i, k; d.keys)
                {
                    s.dependentSchemaNames ~= k;
                    s.dependentSchemas ~= sub(d.values[i], base);
                }

        // in-place applicators
        s.allOf = schemaList(v.get("allOf"), base);
        s.anyOf = schemaList(v.get("anyOf"), base);
        s.oneOf = schemaList(v.get("oneOf"), base);
        if (auto x = v.get("not"))
            s.not = sub(x, base);
        if (auto x = v.get("if"))
            s.ifSchema = sub(x, base);
        if (auto x = v.get("then"))
            s.thenSchema = sub(x, base);
        if (auto x = v.get("else"))
            s.elseSchema = sub(x, base);

        // references
        if (auto r = v.get("$ref"))
            if (r.isString)
            {
                s.ref_.present = true;
                s.ref_.text = r.str;
            }
        if (auto r = v.get("$dynamicRef"))
            if (r.isString)
            {
                s.dynamicRef.present = true;
                s.dynamicRef.text = r.str;
            }

        // indexed but never applied
        if (auto d = v.get("$defs"))
            if (d.isObject)
                foreach (x; d.values)
                    sub(x, base);
        if (auto x = v.get("contentSchema"))
            sub(x, base);
    }

    private static uint typeBit(string name)
    {
        switch (name)
        {
        case "null":
            return TypeBits.null_;
        case "boolean":
            return TypeBits.boolean;
        case "object":
            return TypeBits.object;
        case "array":
            return TypeBits.array;
        case "number":
            return TypeBits.number;
        case "string":
            return TypeBits.string;
        case "integer":
            return TypeBits.integer;
        default:
            return 0;
        }
    }

    // ---- reference resolution -----------------------------------------

    /// Resolves (once) the static target of `info`, a reference found in a
    /// schema whose base URI is `baseUri`.
    Schema resolveRef(ref RefInfo info, string baseUri)
    {
        if (info.resolved)
            return info.target;
        auto u = resolveString(baseUri, info.text);
        immutable docPart = u.withoutFragment().toString();
        immutable frag = u.hasFragment ? percentDecode(u.fragment) : "";
        Schema target;
        if (frag.length == 0)
        {
            if (auto p = docPart in resources)
                target = *p;
        }
        else if (frag[0] == '/')
        {
            if (auto p = docPart in resources)
            {
                auto rawNode = evalPointer(resourceRaw[docPart], frag);
                if (rawNode !is null)
                {
                    if (auto q = rawNode in nodes)
                        target = *q;
                    else
                        target = compile(rawNode, (*p).baseUri);
                }
            }
        }
        else
        {
            immutable key = docPart ~ "#" ~ frag;
            if (auto p = key in anchors)
                target = *p;
            else if (auto p = key in dynAnchors)
                target = *p;
            info.anchorName = frag;
        }
        if (target is null)
            throw new SchemaException("unresolvable reference: " ~ info.text ~ " (from '" ~ baseUri ~ "')");
        if (auto id = docPart in baseIds)
            info.docBase = *id;
        info.target = target;
        info.resolved = true;
        return target;
    }

    /// Resolves a `$dynamicRef` of a schema with base `baseUri` given the
    /// dynamic scope (base ids, outermost first).
    Schema dynamicTarget(ref RefInfo info, string baseUri, const(int)[] scope_)
    {
        auto staticTarget = resolveRef(info, baseUri);
        if (info.anchorName.length == 0 || info.docBase < 0)
            return staticTarget;
        auto byBase = info.anchorName in dynByName;
        if (byBase is null || !(info.docBase in *byBase))
            return staticTarget;
        foreach (b; scope_)
            if (auto p = b in *byBase)
                return *p;
        return staticTarget;
    }
}

unittest
{
    auto reg = new Registry;
    auto doc = parseJson(`{"$id":"http://x.test/a/root.json","$defs":{"n":{"$anchor":"n","type":"integer"}},
        "properties":{"p":{"$ref":"#/$defs/n"}, "q":{"$ref":"#n"}}}`);
    auto root = reg.add(doc, "");
    auto t = reg.resolveRef(root.properties["p"].ref_, root.properties["p"].baseUri);
    assert(t.typeMask == TypeBits.integer);
    auto t2 = reg.resolveRef(root.properties["q"].ref_, root.properties["q"].baseUri);
    assert(t is t2);
}
