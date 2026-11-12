/**
 * The schema evaluator: decides whether an instance satisfies a schema and,
 * when `unevaluatedItems` / `unevaluatedProperties` need them, collects the
 * evaluated-items and evaluated-properties annotation sets.
 */
module jsonschema.validator;

import jsonschema.json;
import jsonschema.number;
import jsonschema.regex;
import jsonschema.schema;

/// Annotation sets produced by evaluating a schema object.
struct Annotations
{
    bool allItems; /// every index is evaluated
    size_t prefix; /// indices below this are evaluated
    bool[size_t] items; /// further evaluated indices
    bool[string] props; /// evaluated property names

    /// Adds everything from `o`.
    void merge(ref Annotations o)
    {
        allItems = allItems || o.allItems;
        if (o.prefix > prefix)
            prefix = o.prefix;
        foreach (k, _; o.items)
            items[k] = true;
        foreach (k, _; o.props)
            props[k] = true;
    }

    /// True when array index `i` is evaluated.
    bool hasItem(size_t i)
    {
        return allItems || i < prefix || (i in items) !is null;
    }
}

/// Evaluates instances against a compiled root schema.
final class Validator
{
    private Registry reg;
    private Schema root;
    private int[] scopeStack;

    /// `root` must have been compiled by `registry`.
    this(Registry registry, Schema root)
    {
        reg = registry;
        this.root = root;
    }

    /// True when `instance` satisfies the root schema.
    bool isValid(JsonValue instance)
    {
        scopeStack.length = 0;
        Annotations a;
        return eval(root, instance, false, a);
    }

    private bool eval(Schema s, JsonValue inst, bool want, ref Annotations ann)
    {
        if (s.isBool)
            return s.boolValue;
        bool pushed = false;
        if (scopeStack.length == 0 || scopeStack[$ - 1] != s.baseId)
        {
            scopeStack ~= s.baseId;
            pushed = true;
        }
        scope (exit)
            if (pushed)
                scopeStack.length = scopeStack.length - 1;

        immutable collect = want || s.hasUnevaluated;
        Annotations la;

        if (!checkGeneric(s, inst))
            return false;

        switch (inst.type)
        {
        case JsonType.number:
            if (!checkNumber(s, inst.number))
                return false;
            break;
        case JsonType.string:
            if (!checkString(s, inst.str))
                return false;
            break;
        case JsonType.array:
            if (!checkArray(s, inst, collect, la))
                return false;
            break;
        case JsonType.object:
            if (!checkObject(s, inst, collect, la))
                return false;
            break;
        default:
            break;
        }

        if (!checkApplicators(s, inst, collect, la))
            return false;

        if (s.hasUnevaluated)
        {
            if (inst.isArray && s.unevaluatedItems !is null)
            {
                bool applied = false;
                foreach (i, x; inst.items)
                {
                    if (la.hasItem(i))
                        continue;
                    applied = true;
                    Annotations dummy;
                    if (!eval(s.unevaluatedItems, x, false, dummy))
                        return false;
                }
                if (applied)
                    la.allItems = true;
            }
            if (inst.isObject && s.unevaluatedProperties !is null)
            {
                foreach (i, k; inst.keys)
                {
                    if (k in la.props)
                        continue;
                    Annotations dummy;
                    if (!eval(s.unevaluatedProperties, inst.values[i], false, dummy))
                        return false;
                    la.props[k] = true;
                }
            }
        }
        if (want)
            ann = la;
        return true;
    }

    // type, enum, const
    private bool checkGeneric(Schema s, JsonValue inst)
    {
        if (s.typeMask != 0)
        {
            uint bits;
            final switch (inst.type)
            {
            case JsonType.null_:
                bits = TypeBits.null_;
                break;
            case JsonType.boolean:
                bits = TypeBits.boolean;
                break;
            case JsonType.number:
                bits = TypeBits.number | (inst.number.isInteger ? TypeBits.integer : 0);
                break;
            case JsonType.string:
                bits = TypeBits.string;
                break;
            case JsonType.array:
                bits = TypeBits.array;
                break;
            case JsonType.object:
                bits = TypeBits.object;
                break;
            }
            if (!(s.typeMask & bits))
                return false;
        }
        if (s.hasEnum)
        {
            bool found = false;
            foreach (e; s.enumValues)
                if (jsonEqual(e, inst))
                {
                    found = true;
                    break;
                }
            if (!found)
                return false;
        }
        if (s.constValue !is null && !jsonEqual(s.constValue, inst))
            return false;
        return true;
    }

    private bool checkNumber(Schema s, ref const Number n)
    {
        if (!s.multipleOf.isNull && !n.isMultipleOf(s.multipleOf.get))
            return false;
        if (!s.maximum.isNull && n > s.maximum.get)
            return false;
        if (!s.minimum.isNull && n < s.minimum.get)
            return false;
        if (!s.exclusiveMaximum.isNull && n >= s.exclusiveMaximum.get)
            return false;
        if (!s.exclusiveMinimum.isNull && n <= s.exclusiveMinimum.get)
            return false;
        return true;
    }

    private static long codePointLength(string str)
    {
        long n = 0;
        foreach (c; cast(const(ubyte)[]) str)
            if ((c & 0xC0) != 0x80)
                n++;
        return n;
    }

    private bool checkString(Schema s, string str)
    {
        if (s.minLength >= 0 || s.maxLength >= 0)
        {
            immutable len = codePointLength(str);
            if (s.minLength >= 0 && len < s.minLength)
                return false;
            if (s.maxLength >= 0 && len > s.maxLength)
                return false;
        }
        if (s.hasPattern && !reg.regexes.get(s.pattern).matches(str))
            return false;
        return true;
    }

    private bool checkArray(Schema s, JsonValue inst, bool collect, ref Annotations la)
    {
        auto items = inst.items;
        immutable len = items.length;
        if (s.minItems >= 0 && len < s.minItems)
            return false;
        if (s.maxItems >= 0 && len > s.maxItems)
            return false;
        if (s.uniqueItems && !allUnique(items))
            return false;
        Annotations dummy;
        size_t start = 0;
        if (s.hasPrefixItems)
        {
            immutable n = len < s.prefixItems.length ? len : s.prefixItems.length;
            foreach (i; 0 .. n)
                if (!eval(s.prefixItems[i], items[i], false, dummy))
                    return false;
            start = s.prefixItems.length;
            if (collect && n > la.prefix)
                la.prefix = n;
        }
        if (s.items !is null)
        {
            foreach (i; start .. len)
                if (!eval(s.items, items[i], false, dummy))
                    return false;
            if (collect)
                la.allItems = true;
        }
        if (s.contains !is null)
        {
            immutable minC = s.minContains >= 0 ? s.minContains : 1;
            immutable maxC = s.maxContains;
            long count = 0;
            foreach (i; 0 .. len)
            {
                if (eval(s.contains, items[i], false, dummy))
                {
                    count++;
                    if (collect)
                        la.items[i] = true;
                    else if (maxC < 0 && count >= minC)
                        break;
                }
            }
            if (count < minC)
                return false;
            if (maxC >= 0 && count > maxC)
                return false;
        }
        return true;
    }

    private static bool allUnique(JsonValue[] items)
    {
        if (items.length < 2)
            return true;
        if (items.length <= 8)
        {
            foreach (i; 1 .. items.length)
                foreach (j; 0 .. i)
                    if (jsonEqual(items[i], items[j]))
                        return false;
            return true;
        }
        JsonValue[][ulong] seen;
        foreach (x; items)
        {
            immutable h = jsonHash(x);
            if (auto p = h in seen)
            {
                foreach (y; *p)
                    if (jsonEqual(x, y))
                        return false;
                *p ~= x;
            }
            else
                seen[h] = [x];
        }
        return true;
    }

    private bool checkObject(Schema s, JsonValue inst, bool collect, ref Annotations la)
    {
        immutable count = inst.keys.length;
        if (s.minProperties >= 0 && count < s.minProperties)
            return false;
        if (s.maxProperties >= 0 && count > s.maxProperties)
            return false;
        foreach (r; s.required)
            if ((r in inst.map) is null)
                return false;
        foreach (i, name; s.dependentRequiredNames)
            if (name in inst.map)
                foreach (r; s.dependentRequiredLists[i])
                    if ((r in inst.map) is null)
                        return false;

        immutable hasProps = s.properties.length != 0;
        immutable hasPatterns = s.patternProperties.length != 0;
        if (hasProps || hasPatterns || s.additionalProperties !is null)
        {
            Annotations dummy;
            foreach (i, name; inst.keys)
            {
                auto value = inst.values[i];
                bool matched = false;
                if (hasProps)
                    if (auto p = name in s.properties)
                    {
                        matched = true;
                        if (!eval(*p, value, false, dummy))
                            return false;
                    }
                if (hasPatterns)
                    foreach (ref pe; s.patternProperties)
                        if (reg.regexes.get(pe.pattern).matches(name))
                        {
                            matched = true;
                            if (!eval(pe.schema, value, false, dummy))
                                return false;
                        }
                if (matched)
                {
                    if (collect)
                        la.props[name] = true;
                }
                else if (s.additionalProperties !is null)
                {
                    if (!eval(s.additionalProperties, value, false, dummy))
                        return false;
                    if (collect)
                        la.props[name] = true;
                }
            }
        }
        if (s.propertyNames !is null)
        {
            Annotations dummy;
            foreach (k; inst.keys)
                if (!eval(s.propertyNames, JsonValue.makeString(k), false, dummy))
                    return false;
        }
        return true;
    }

    private bool checkApplicators(Schema s, JsonValue inst, bool collect, ref Annotations la)
    {
        if (s.ref_.present)
        {
            auto target = reg.resolveRef(s.ref_, s.baseUri);
            if (!applyInPlace(target, inst, collect, la))
                return false;
        }
        if (s.dynamicRef.present)
        {
            auto target = reg.dynamicTarget(s.dynamicRef, s.baseUri, scopeStack);
            if (!applyInPlace(target, inst, collect, la))
                return false;
        }
        foreach (c; s.allOf)
            if (!applyInPlace(c, inst, collect, la))
                return false;
        if (s.anyOf.length)
        {
            bool any = false;
            foreach (c; s.anyOf)
            {
                Annotations a;
                if (eval(c, inst, collect, a))
                {
                    any = true;
                    if (!collect)
                        break;
                    la.merge(a);
                }
            }
            if (!any)
                return false;
        }
        if (s.oneOf.length)
        {
            int matches = 0;
            foreach (c; s.oneOf)
            {
                Annotations a;
                if (eval(c, inst, collect, a))
                {
                    matches++;
                    if (matches > 1)
                        return false;
                    la.merge(a);
                }
            }
            if (matches != 1)
                return false;
        }
        if (s.not !is null)
        {
            Annotations a;
            if (eval(s.not, inst, false, a))
                return false;
        }
        if (s.ifSchema !is null)
        {
            Annotations a;
            if (eval(s.ifSchema, inst, collect, a))
            {
                la.merge(a);
                if (s.thenSchema !is null && !applyInPlace(s.thenSchema, inst, collect, la))
                    return false;
            }
            else if (s.elseSchema !is null && !applyInPlace(s.elseSchema, inst, collect, la))
                return false;
        }
        if (inst.isObject)
            foreach (i, name; s.dependentSchemaNames)
                if (name in inst.map)
                    if (!applyInPlace(s.dependentSchemas[i], inst, collect, la))
                        return false;
        return true;
    }

    private bool applyInPlace(Schema c, JsonValue inst, bool collect, ref Annotations la)
    {
        Annotations a;
        if (!eval(c, inst, collect, a))
            return false;
        if (collect)
            la.merge(a);
        return true;
    }
}

version (unittest)
{
    import jsonschema.runner : SchemaValidator;

    private bool check(string schema, string instance)
    {
        return new SchemaValidator(parseJson(schema)).isValid(parseJson(instance));
    }
}

unittest
{
    // type, numbers
    assert(check(`{"type":"integer"}`, `1.0`));
    assert(!check(`{"type":"integer"}`, `1.5`));
    assert(!check(`{"type":"number"}`, `true`));
    assert(check(`{"type":["null","string"]}`, `null`));
    assert(check(`{"maximum":1e308}`, `1e308`));
    assert(!check(`{"maximum":1e308}`, `1e309`));
    assert(!check(`{"exclusiveMinimum":0}`, `0`));
    assert(check(`{"minimum":1}`, `"inert for strings"`));
}

unittest
{
    // strings and patterns
    assert(check(`{"pattern":"bar"}`, `"foobarbaz"`));
    assert(!check(`{"pattern":"^bar"}`, `"foobarbaz"`));
    assert(check(`{"minLength":2.0}`, `"e\u0301"`));
    assert(!check(`{"minLength":2}`, `"💩"`));
}

unittest
{
    // arrays
    assert(!check(`{"uniqueItems":true}`, `[1,true,1.0]`));
    assert(check(`{"uniqueItems":true}`, `[1,true,"1",[1],{"a":1}]`));
    assert(check(`{"prefixItems":[{"type":"integer"}],"items":{"type":"string"}}`, `[1,"a"]`));
    assert(!check(`{"prefixItems":[{"type":"integer"}],"items":{"type":"string"}}`, `[1,2]`));
    assert(check(`{"contains":{"const":1},"minContains":0}`, `[]`));
    assert(!check(`{"contains":{"const":1}}`, `[]`));
    assert(check(`{"minContains":5}`, `[]`)); // inert without contains
}

unittest
{
    // objects
    assert(!check(`{"required":["a"]}`, `{}`));
    assert(check(`{"required":["a"]}`, `[]`));
    assert(!check(`{"dependentRequired":{"a":["b"]}}`, `{"a":1}`));
    assert(check(`{"dependentRequired":{"a":["b"]}}`, `{"b":1}`));
    assert(!check(`{"propertyNames":{"maxLength":1}}`, `{"ab":1}`));
    assert(!check(`{"patternProperties":{"^a":{"type":"integer"},"b$":{"minimum":5}}}`, `{"ab":1}`));
    assert(!check(`{"properties":{"a":true},"additionalProperties":false}`, `{"a":1,"b":2}`));
    assert(check(`{"patternProperties":{"^x-":true},"additionalProperties":false}`, `{"x-a":1}`));
    assert(!check(`{"dependentSchemas":{"a":{"required":["b"]}}}`, `{"a":1}`));
}

unittest
{
    // in-place applicators
    assert(check(`{"oneOf":[{"type":"integer"},{"minimum":5}]}`, `3`));
    assert(!check(`{"oneOf":[{"type":"integer"},{"minimum":5}]}`, `6`));
    assert(check(`{"anyOf":[false,true]}`, `0`));
    assert(!check(`{"not":{"type":"string"}}`, `"x"`));
    assert(!check(`{"if":{"type":"string"},"then":{"minLength":3},"else":{"type":"integer"}}`, `"ab"`));
    assert(check(`{"if":{"type":"string"},"then":{"minLength":3},"else":{"type":"integer"}}`, `7`));
    assert(check(`{"then":false}`, `1`)); // then without if is inert
}

unittest
{
    // unevaluated*
    assert(!check(`{"prefixItems":[true],"unevaluatedItems":false}`, `[1,2]`));
    assert(check(`{"prefixItems":[true],"unevaluatedItems":false}`, `[1]`));
    assert(check(`{"contains":{"const":2},"unevaluatedItems":false}`, `[2,2]`));
    assert(!check(`{"contains":{"const":2},"unevaluatedItems":false}`, `[2,3]`));
    // annotations from failed anyOf branches are dropped
    assert(!check(`{"anyOf":[{"properties":{"a":true},"required":["z"]}],"unevaluatedProperties":false,"properties":{"q":true}}`,
            `{"a":1}`));
    assert(check(`{"$ref":"#/$defs/p","unevaluatedProperties":false,"$defs":{"p":{"properties":{"a":true}}}}`, `{"a":1}`));
    // not never contributes annotations
    assert(!check(`{"not":{"not":{"properties":{"a":true}}},"unevaluatedProperties":false}`, `{"a":1}`));
}

unittest
{
    // references and anchors
    assert(check(`{"$defs":{"a":{"type":"integer"}},"properties":{"x":{"$ref":"#/$defs/a"}}}`, `{"x":1}`));
    assert(!check(`{"$defs":{"a":{"type":"integer"}},"properties":{"x":{"$ref":"#/$defs/a"}}}`, `{"x":"s"}`));
    assert(!check(`{"$defs":{"a b":{"type":"integer"}},"$ref":"#/$defs/a%20b"}`, `"s"`));
    assert(!check(`{"$defs":{"a~b":{"type":"integer"},"c/d":{"type":"string"}},"allOf":[{"$ref":"#/$defs/a~0b"},{"$ref":"#/$defs/c~1d"}]}`, `1`));
    assert(!check(`{"$defs":{"a":{"$anchor":"foo","type":"integer"}},"$ref":"#foo"}`, `"s"`));
    // recursion
    assert(check(`{"$ref":"#/$defs/t","$defs":{"t":{"type":"object","properties":{"n":{"$ref":"#/$defs/t"}}}}}`, `{"n":{"n":{}}}`));
    assert(!check(`{"$ref":"#/$defs/t","$defs":{"t":{"type":"object","properties":{"n":{"$ref":"#/$defs/t"}}}}}`, `{"n":{"n":1}}`));
    // sibling keywords of $ref still apply
    assert(!check(`{"$ref":"#/$defs/a","maximum":2,"$defs":{"a":{"type":"integer"}}}`, `3`));
}

unittest
{
    // unknown keywords and their contents are inert
    assert(check(`{"definitions":{"x":{"type":"string"}},"properties":{"p":{"$ref":"#/definitions/x"}},"foo":false}`, `{"p":"s"}`));
    assert(check(`{"format":"ipv4","type":"string"}`, `"nope"`));
    assert(check(`{"const":{"$id":"http://x/y","type":"string"}}`, `{"$id":"http://x/y","type":"string"}`));
}
