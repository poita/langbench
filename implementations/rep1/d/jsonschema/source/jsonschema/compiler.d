/**
 * Schema compilation and the schema registry.
 *
 * $(LREF SchemaRegistry) walks every schema document once (SPEC 6.2),
 * tracking base URIs, creating one $(MREF jsonschema.node.Node) per schema
 * object, registering resources and anchors, and finally resolving
 * `$ref` / `$dynamicRef` targets.
 */
module jsonschema.compiler;

import jsonschema.json;
import jsonschema.node;
import jsonschema.number;
import jsonschema.pointer;
import jsonschema.regex;
import jsonschema.uri;

/// Thrown when a schema cannot be compiled (for example an invalid `pattern`).
class SchemaException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

private struct Resource
{
    const(Value)* value;
    Node node;
}

/// Combines a base id and a name id into one map key.
ulong anchorKey(uint baseId, uint nameId) pure nothrow @nogc
{
    return (cast(ulong) baseId << 32) | nameId;
}

/**
 * Holds all compiled schema documents and the indexes needed to resolve
 * references between them.
 */
final class SchemaRegistry
{
    private uint[string] ids;
    private Node[const(Value)*] nodeOf;
    private Resource[string] resources;
    private Node[ulong] plainAnchors;
    private Node[ulong] dynamicAnchorMap;
    private Node[] pending;
    private Regex[string] regexCache;
    private string[] idStrings;

    /// Returns the interned id of `s`, assigning one if needed.
    uint intern(string s)
    {
        if (auto p = s in ids)
            return *p;
        immutable id = cast(uint) idStrings.length;
        idStrings ~= s;
        ids[s] = id;
        return id;
    }

    /// The string behind an interned id.
    string internedString(uint id) const
    {
        return idStrings[id];
    }

    /**
     * Compiles a schema document whose retrieval URI is `retrievalUri`
     * and returns the root node. The document is registered under every
     * `$id` it declares and, if still free, under its retrieval URI.
     */
    Node addDocument(Value doc, string retrievalUri = "")
    {
        auto root = new Value;
        *root = doc;
        auto node = compileSchema(root, retrievalUri, intern(retrievalUri));
        if (retrievalUri !in resources)
            resources[retrievalUri] = Resource(root, node);
        return node;
    }

    /// The root node of the resource registered under `uri`, or null.
    Node lookupResource(string uri)
    {
        if (auto r = uri in resources)
            return r.node;
        return null;
    }

    /// The target of a dynamic anchor `name` under the base with id `baseId`, or null.
    Node dynamicAnchorTarget(uint baseId, uint nameId)
    {
        immutable key = anchorKey(baseId, nameId);
        if (key !in dynamicAnchorMap)
            return null;
        if (auto p = key in plainAnchors)
            return *p;
        return dynamicAnchorMap[key];
    }

    /// True if `(baseId, nameId)` is a dynamic anchor.
    bool isDynamicAnchor(uint baseId, uint nameId) const
    {
        return (anchorKey(baseId, nameId) in dynamicAnchorMap) !is null;
    }

    private Regex compileRegex(string pattern)
    {
        if (auto r = pattern in regexCache)
            return *r;
        Regex r;
        try
            r = new Regex(pattern);
        catch (RegexException e)
            throw new SchemaException("invalid regular expression '" ~ pattern ~ "': " ~ e.msg);
        regexCache[pattern] = r;
        return r;
    }

    private Node compileSub(const(Value)* v, string base, uint baseId)
    {
        return compileSchema(v, base, baseId);
    }

    private Node[] compileArray(const(Value)* v, string base, uint baseId)
    {
        Node[] r;
        if (v.kind != Kind.array)
            return r;
        foreach (ref e; v.array)
            r ~= compileSub(&e, base, baseId);
        return r;
    }

    private static bool isSchema(const(Value)* v)
    {
        return v.kind == Kind.object || v.kind == Kind.boolean;
    }

    private Node compileSchema(const(Value)* v, string base, uint baseId)
    {
        auto n = new Node;
        nodeOf[v] = n;
        if (v.kind == Kind.boolean)
        {
            n.baseId = baseId;
            n.form = v.boolean ? Form.alwaysTrue : Form.alwaysFalse;
            return n;
        }
        if (v.kind != Kind.object)
        {
            n.baseId = baseId;
            n.form = Form.alwaysTrue;
            return n;
        }
        auto obj = v.object;

        if (auto idv = obj.find("$id"))
        {
            if (idv.kind == Kind.string)
            {
                string frag;
                bool hasFrag;
                base = splitFragment(resolve(idv.str, base), frag, hasFrag);
                baseId = intern(base);
                if (base !in resources)
                    resources[base] = Resource(v, n);
            }
        }
        n.baseId = baseId;

        if (auto a = obj.find("$anchor"))
        {
            if (a.kind == Kind.string)
            {
                immutable key = anchorKey(baseId, intern(a.str));
                if (key !in plainAnchors)
                    plainAnchors[key] = n;
            }
        }
        if (auto a = obj.find("$dynamicAnchor"))
        {
            if (a.kind == Kind.string)
            {
                immutable key = anchorKey(baseId, intern(a.str));
                if (key !in dynamicAnchorMap)
                    dynamicAnchorMap[key] = n;
            }
        }

        foreach (ref m; obj.members)
        {
            const(Value)* val = &m.value;
            switch (m.key)
            {
            case "type":
                compileType(n, val);
                break;
            case "enum":
                if (val.kind == Kind.array)
                {
                    n.hasEnum = true;
                    n.enumValues = val.array;
                }
                break;
            case "const":
                n.constValue = val;
                break;
            case "multipleOf":
                n.multipleOf = numberOf(val);
                break;
            case "maximum":
                n.maximum = numberOf(val);
                break;
            case "minimum":
                n.minimum = numberOf(val);
                break;
            case "exclusiveMaximum":
                n.exclusiveMaximum = numberOf(val);
                break;
            case "exclusiveMinimum":
                n.exclusiveMinimum = numberOf(val);
                break;
            case "maxLength":
                setCount(val, n.maxLength);
                break;
            case "minLength":
                setCount(val, n.minLength);
                break;
            case "maxItems":
                setCount(val, n.maxItems);
                break;
            case "minItems":
                setCount(val, n.minItems);
                break;
            case "maxProperties":
                setCount(val, n.maxProperties);
                break;
            case "minProperties":
                setCount(val, n.minProperties);
                break;
            case "maxContains":
                setCount(val, n.maxContains);
                break;
            case "minContains":
                setCount(val, n.minContains);
                break;
            case "pattern":
                if (val.kind == Kind.string)
                    n.pattern = compileRegex(val.str);
                break;
            case "uniqueItems":
                n.uniqueItems = val.kind == Kind.boolean && val.boolean;
                break;
            case "required":
                if (val.kind == Kind.array)
                    foreach (ref e; val.array)
                        if (e.kind == Kind.string)
                            n.required ~= e.str;
                break;
            case "dependentRequired":
                if (val.kind == Kind.object)
                {
                    foreach (ref dm; val.object.members)
                    {
                        DependentRequired d;
                        d.name = dm.key;
                        if (dm.value.kind == Kind.array)
                            foreach (ref e; dm.value.array)
                                if (e.kind == Kind.string)
                                    d.required ~= e.str;
                        n.dependentRequired ~= d;
                    }
                }
                break;
            case "prefixItems":
                if (val.kind == Kind.array)
                {
                    n.hasPrefixItems = true;
                    n.prefixItems = compileArray(val, base, baseId);
                }
                break;
            case "items":
                if (isSchema(val))
                    n.items = compileSub(val, base, baseId);
                break;
            case "contains":
                if (isSchema(val))
                    n.contains = compileSub(val, base, baseId);
                break;
            case "properties":
                if (val.kind == Kind.object)
                {
                    n.hasProperties = true;
                    foreach (ref pm; val.object.members)
                        n.properties[pm.key] = compileSub(&pm.value, base, baseId);
                }
                break;
            case "patternProperties":
                if (val.kind == Kind.object)
                {
                    foreach (ref pm; val.object.members)
                    {
                        auto re = compileRegex(pm.key);
                        n.patternProperties ~= PatternProperty(re, compileSub(&pm.value, base, baseId));
                    }
                }
                break;
            case "additionalProperties":
                if (isSchema(val))
                    n.additionalProperties = compileSub(val, base, baseId);
                break;
            case "propertyNames":
                if (isSchema(val))
                    n.propertyNames = compileSub(val, base, baseId);
                break;
            case "dependentSchemas":
                if (val.kind == Kind.object)
                    foreach (ref dm; val.object.members)
                        n.dependentSchemas ~= DependentSchema(dm.key, compileSub(&dm.value, base, baseId));
                break;
            case "allOf":
                n.allOf = compileArray(val, base, baseId);
                break;
            case "anyOf":
                n.anyOf = compileArray(val, base, baseId);
                break;
            case "oneOf":
                n.oneOf = compileArray(val, base, baseId);
                break;
            case "not":
                if (isSchema(val))
                    n.not = compileSub(val, base, baseId);
                break;
            case "if":
                if (isSchema(val))
                    n.ifSchema = compileSub(val, base, baseId);
                break;
            case "then":
                if (isSchema(val))
                    n.thenSchema = compileSub(val, base, baseId);
                break;
            case "else":
                if (isSchema(val))
                    n.elseSchema = compileSub(val, base, baseId);
                break;
            case "unevaluatedItems":
                if (isSchema(val))
                    n.unevaluatedItems = compileSub(val, base, baseId);
                break;
            case "unevaluatedProperties":
                if (isSchema(val))
                    n.unevaluatedProperties = compileSub(val, base, baseId);
                break;
            case "$defs":
                // Indexed (for $ref targets) but never applied.
                if (val.kind == Kind.object)
                    foreach (ref dm; val.object.members)
                        compileSub(&dm.value, base, baseId);
                break;
            case "contentSchema":
                if (isSchema(val))
                    compileSub(val, base, baseId);
                break;
            case "$ref":
                if (val.kind == Kind.string)
                {
                    n.hasRef = true;
                    n.refText = val.str;
                    pending ~= n;
                }
                break;
            case "$dynamicRef":
                if (val.kind == Kind.string)
                {
                    n.hasDynamicRef = true;
                    n.dynamicRefText = val.str;
                    pending ~= n;
                }
                break;
            default:
                break;
            }
        }
        return n;
    }

    private static Number* numberOf(const(Value)* v)
    {
        if (v.kind != Kind.number)
            return null;
        auto r = new Number;
        *r = cast(Number) v.number;
        return r;
    }

    private static void setCount(const(Value)* v, ref long field)
    {
        if (v.kind != Kind.number)
            return;
        field = v.number.toCount();
    }

    private static void compileType(Node n, const(Value)* v)
    {
        ubyte bitFor(string s)
        {
            switch (s)
            {
            case "null":
                return TypeBit.null_;
            case "boolean":
                return TypeBit.boolean;
            case "object":
                return TypeBit.object;
            case "array":
                return TypeBit.array;
            case "number":
                return TypeBit.number;
            case "string":
                return TypeBit.string;
            case "integer":
                return TypeBit.integer;
            default:
                return 0;
            }
        }

        if (v.kind == Kind.string)
            n.typeMask = bitFor(v.str);
        else if (v.kind == Kind.array)
        {
            foreach (ref e; v.array)
                if (e.kind == Kind.string)
                    n.typeMask |= bitFor(e.str);
        }
        else
            return;
        // An unrecognised type name must not turn into "no restriction".
        if (n.typeMask == 0)
            n.typeMask = 0x80;
    }

    /**
     * Resolves every `$ref` and `$dynamicRef` compiled so far. Unresolvable
     * references are left with a null target (they reject if ever evaluated).
     */
    void resolveReferences()
    {
        auto todo = pending;
        pending = null;
        foreach (n; todo)
        {
            if (n.refsResolved)
                continue;
            n.refsResolved = true;
            string base = idStrings[n.baseId];
            if (n.hasRef)
            {
                bool plain;
                string name;
                n.refTarget = lookupRef(n.refText, base, plain, name);
            }
            if (n.hasDynamicRef)
            {
                bool plain;
                string name;
                string docPart;
                n.dynamicRefTarget = lookupRef(n.dynamicRefText, base, plain, name, &docPart);
                if (plain)
                {
                    if (auto docId = docPart in ids)
                    {
                        immutable nameId = intern(name);
                        if (isDynamicAnchor(*docId, nameId))
                        {
                            n.dynamicRefIsDynamic = true;
                            n.dynamicRefName = nameId;
                        }
                    }
                }
            }
        }
    }

    /// True if there are references that still need `resolveReferences()`.
    bool needsResolve() const
    {
        return pending.length != 0;
    }

    private Node lookupRef(string text, string base, out bool plainName, out string anchorName,
            string* docPartOut = null)
    {
        string fragEnc;
        bool hasFrag;
        auto docPart = splitFragment(resolve(text, base), fragEnc, hasFrag);
        if (docPartOut)
            *docPartOut = docPart;
        auto frag = percentDecode(fragEnc);
        auto res = docPart in resources;
        if (frag.length == 0)
            return res ? res.node : null;
        if (frag[0] == '/')
        {
            if (res is null)
                return null;
            auto target = evaluatePointer(res.value, frag);
            if (target is null)
                return null;
            if (auto nd = target in nodeOf)
                return *nd;
            return null;
        }
        plainName = true;
        anchorName = frag;
        auto docId = docPart in ids;
        auto nameId = frag in ids;
        if (docId is null || nameId is null)
            return null;
        immutable key = anchorKey(*docId, *nameId);
        if (auto p = key in plainAnchors)
            return *p;
        if (auto p = key in dynamicAnchorMap)
            return *p;
        return null;
    }
}
