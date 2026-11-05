/**
 * Compiled schema nodes.
 *
 * A $(LREF Node) holds one schema object with its keywords decoded into
 * evaluation-ready form. Nodes are created by $(MREF jsonschema.compiler)
 * and interpreted by $(MREF jsonschema.evaluator).
 */
module jsonschema.node;

import jsonschema.json;
import jsonschema.number;
import jsonschema.regex;

/// Bits of `Node.typeMask`.
enum TypeBit : ubyte
{
    null_ = 1,
    boolean = 2,
    object = 4,
    array = 8,
    number = 16,
    string = 32,
    integer = 64
}

/// A `dependentRequired` entry.
struct DependentRequired
{
    string name;
    string[] required;
}

/// A `dependentSchemas` entry.
struct DependentSchema
{
    string name;
    Node schema;
}

/// A `patternProperties` entry.
struct PatternProperty
{
    Regex pattern;
    Node schema;
}

/// What kind of schema a node is.
enum Form : ubyte
{
    /// An object schema: evaluate its keywords.
    keywords,
    /// The boolean schema `true`.
    alwaysTrue,
    /// The boolean schema `false`.
    alwaysFalse
}

/// One compiled schema (object or boolean).
final class Node
{
    /// Interned base URI of the schema resource that contains this schema.
    uint baseId;
    Form form;

    // Any type
    ubyte typeMask;
    const(Value)[] enumValues;
    bool hasEnum;
    const(Value)* constValue;

    // Numbers
    Number* multipleOf, maximum, minimum, exclusiveMaximum, exclusiveMinimum;

    // Strings
    long minLength = 0, maxLength = long.max;
    Regex pattern;

    // Arrays
    long minItems = 0, maxItems = long.max;
    bool uniqueItems;
    Node[] prefixItems;
    bool hasPrefixItems;
    Node items;
    Node contains;
    long minContains = 1, maxContains = long.max;

    // Objects
    long minProperties = 0, maxProperties = long.max;
    string[] required;
    DependentRequired[] dependentRequired;
    Node[string] properties;
    bool hasProperties;
    PatternProperty[] patternProperties;
    Node additionalProperties;
    Node propertyNames;
    DependentSchema[] dependentSchemas;

    // In-place applicators
    Node[] allOf, anyOf, oneOf;
    Node not;
    Node ifSchema, thenSchema, elseSchema;
    Node unevaluatedItems, unevaluatedProperties;

    // References (targets are filled in by SchemaRegistry.resolve)
    string refText;
    Node refTarget;
    bool hasRef;
    string dynamicRefText;
    Node dynamicRefTarget;
    bool hasDynamicRef;
    /// True when `$dynamicRef` names a dynamic anchor, so the dynamic scope decides.
    bool dynamicRefIsDynamic;
    /// Interned anchor name for dynamic resolution.
    uint dynamicRefName;
    /// Whether the references of this node have been resolved.
    bool refsResolved;
}
