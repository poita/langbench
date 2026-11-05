/**
 * The schema evaluator: applies compiled $(MREF jsonschema.node.Node)s to
 * instances, collecting the annotations that `unevaluatedItems` and
 * `unevaluatedProperties` need.
 */
module jsonschema.evaluator;

import jsonschema.compiler;
import jsonschema.json;
import jsonschema.node;
import jsonschema.number;

/// Evaluated array indices / object member positions, as lazily allocated bitsets.
private struct Annotations
{
    bool allItems, allProps;
    ulong[] items, props;

    static void mark(ref ulong[] bits, size_t i, size_t n)
    {
        if (bits.length == 0)
            bits = new ulong[(n + 63) / 64];
        bits[i >> 6] |= 1UL << (i & 63);
    }

    void markItem(size_t i, size_t n)
    {
        if (!allItems)
            mark(items, i, n);
    }

    void markProp(size_t i, size_t n)
    {
        if (!allProps)
            mark(props, i, n);
    }

    bool hasItem(size_t i) const
    {
        return allItems || ((i >> 6) < items.length && ((items[i >> 6] >> (i & 63)) & 1));
    }

    bool hasProp(size_t i) const
    {
        return allProps || ((i >> 6) < props.length && ((props[i >> 6] >> (i & 63)) & 1));
    }

    private static void orInto(ref ulong[] dst, ulong[] src)
    {
        if (src.length == 0)
            return;
        if (dst.length == 0)
        {
            dst = src;
            return;
        }
        // Never mutate a slice that is shared with another Annotations value.
        auto copy = dst.dup;
        foreach (i, w; src)
            copy[i] |= w;
        dst = copy;
    }

    void merge(ref Annotations o)
    {
        allItems = allItems || o.allItems;
        allProps = allProps || o.allProps;
        orInto(items, o.items);
        orInto(props, o.props);
    }
}

/**
 * Validates instances against compiled schemas.
 *
 * The evaluator is recursive; run it on a thread with a large stack when
 * schemas or instances may nest deeply. It keeps the dynamic scope as mutable
 * state, so an instance must not be shared between threads.
 */
final class Evaluator
{
    private SchemaRegistry registry;
    private uint[] scopeStack;
    private size_t sp;

    this(SchemaRegistry registry)
    {
        this.registry = registry;
        scopeStack = new uint[64];
    }

    /// True if `instance` satisfies the schema rooted at `root`.
    bool isValid(Node root, ref const Value instance)
    {
        if (registry.needsResolve)
            registry.resolveReferences();
        sp = 0;
        return eval(root, instance, null);
    }

    private static ubyte typeBits(ref const Value v)
    {
        final switch (v.kind)
        {
        case Kind.null_:
            return TypeBit.null_;
        case Kind.boolean:
            return TypeBit.boolean;
        case Kind.number:
            return v.number.isInteger ? (TypeBit.number | TypeBit.integer) : TypeBit.number;
        case Kind.string:
            return TypeBit.string;
        case Kind.array:
            return TypeBit.array;
        case Kind.object:
            return TypeBit.object;
        }
    }

    private bool eval(Node n, ref const Value v, Annotations* outAnn)
    {
        final switch (n.form)
        {
        case Form.alwaysTrue:
            return true;
        case Form.alwaysFalse:
            return false;
        case Form.keywords:
            break;
        }

        bool pushed = false;
        if (sp == 0 || scopeStack[sp - 1] != n.baseId)
        {
            if (sp == scopeStack.length)
                scopeStack.length = sp * 2;
            scopeStack[sp++] = n.baseId;
            pushed = true;
        }
        scope (exit)
            if (pushed)
                sp--;

        Annotations local;
        Annotations* a = outAnn;
        immutable needsUneval = (v.kind == Kind.array && n.unevaluatedItems !is null)
            || (v.kind == Kind.object && n.unevaluatedProperties !is null);
        if (needsUneval)
            a = &local;

        if (n.typeMask && !(n.typeMask & typeBits(v)))
            return false;
        if (n.constValue && !jsonEqual(v, *n.constValue))
            return false;
        if (n.hasEnum)
        {
            bool found = false;
            foreach (ref e; n.enumValues)
                if (jsonEqual(v, e))
                {
                    found = true;
                    break;
                }
            if (!found)
                return false;
        }

        final switch (v.kind)
        {
        case Kind.null_:
        case Kind.boolean:
            break;
        case Kind.number:
            if (!evalNumber(n, v.number))
                return false;
            break;
        case Kind.string:
            if (!evalString(n, v.str))
                return false;
            break;
        case Kind.array:
            if (!evalArray(n, v.array, a))
                return false;
            break;
        case Kind.object:
            if (!evalObject(n, v.object, a))
                return false;
            break;
        }

        if (!evalInPlace(n, v, a))
            return false;

        if (needsUneval)
        {
            if (v.kind == Kind.array)
            {
                auto arr = v.array;
                foreach (i; 0 .. arr.length)
                    if (!local.hasItem(i) && !eval(n.unevaluatedItems, arr[i], null))
                        return false;
                local.allItems = true;
            }
            else
            {
                auto mem = v.object.members;
                foreach (i; 0 .. mem.length)
                    if (!local.hasProp(i) && !eval(n.unevaluatedProperties, mem[i].value, null))
                        return false;
                local.allProps = true;
            }
            if (outAnn !is null)
                outAnn.merge(local);
        }
        return true;
    }

    private static bool evalNumber(Node n, ref const Number x)
    {
        if (n.multipleOf && !isMultipleOf(x, *n.multipleOf))
            return false;
        if (n.maximum && compare(x, *n.maximum) > 0)
            return false;
        if (n.minimum && compare(x, *n.minimum) < 0)
            return false;
        if (n.exclusiveMaximum && compare(x, *n.exclusiveMaximum) >= 0)
            return false;
        if (n.exclusiveMinimum && compare(x, *n.exclusiveMinimum) <= 0)
            return false;
        return true;
    }

    private static bool evalString(Node n, string s)
    {
        if (n.minLength > 0 || n.maxLength != long.max)
        {
            immutable len = cast(long) codePointLength(s);
            if (len < n.minLength || len > n.maxLength)
                return false;
        }
        if (n.pattern !is null && !n.pattern.matches(s))
            return false;
        return true;
    }

    private bool evalArray(Node n, const(Value)[] arr, Annotations* a)
    {
        immutable len = cast(long) arr.length;
        if (len < n.minItems || len > n.maxItems)
            return false;
        if (n.uniqueItems && hasDuplicates(arr))
            return false;
        immutable collect = a !is null;

        if (n.hasPrefixItems)
        {
            immutable lim = n.prefixItems.length < arr.length ? n.prefixItems.length : arr.length;
            foreach (i; 0 .. lim)
            {
                if (!eval(n.prefixItems[i], arr[i], null))
                    return false;
                if (collect)
                    a.markItem(i, arr.length);
            }
        }
        if (n.items !is null)
        {
            immutable start = n.hasPrefixItems ? n.prefixItems.length : 0;
            foreach (i; start .. arr.length)
                if (!eval(n.items, arr[i], null))
                    return false;
            if (collect)
                a.allItems = true;
        }
        if (n.contains !is null)
        {
            if (collect || n.maxContains != long.max || n.minContains > 0)
            {
                long count = 0;
                foreach (i; 0 .. arr.length)
                {
                    if (!collect && n.maxContains == long.max && count >= n.minContains)
                        break;
                    if (eval(n.contains, arr[i], null))
                    {
                        count++;
                        if (collect)
                            a.markItem(i, arr.length);
                    }
                }
                if (count < n.minContains || count > n.maxContains)
                    return false;
            }
        }
        return true;
    }

    private bool evalObject(Node n, const(JsonObject)* obj, Annotations* a)
    {
        auto mem = obj.members;
        immutable len = cast(long) mem.length;
        if (len < n.minProperties || len > n.maxProperties)
            return false;
        foreach (name; n.required)
            if (obj.find(name) is null)
                return false;
        foreach (ref d; n.dependentRequired)
        {
            if (obj.find(d.name) !is null)
                foreach (r; d.required)
                    if (obj.find(r) is null)
                        return false;
        }
        immutable collect = a !is null;
        immutable hasAdditional = n.additionalProperties !is null;
        if (n.hasProperties || n.patternProperties.length || hasAdditional)
        {
            foreach (i, ref m; mem)
            {
                bool matched = false;
                if (n.hasProperties)
                {
                    if (auto c = m.key in n.properties)
                    {
                        matched = true;
                        if (!eval(*c, m.value, null))
                            return false;
                    }
                }
                foreach (ref pp; n.patternProperties)
                {
                    if (pp.pattern.matches(m.key))
                    {
                        matched = true;
                        if (!eval(pp.schema, m.value, null))
                            return false;
                    }
                }
                if (matched)
                {
                    if (collect)
                        a.markProp(i, mem.length);
                }
                else if (hasAdditional)
                {
                    if (!eval(n.additionalProperties, m.value, null))
                        return false;
                }
            }
            if (collect && hasAdditional)
                a.allProps = true;
        }
        if (n.propertyNames !is null)
        {
            foreach (ref m; mem)
            {
                auto kv = Value.makeString(m.key);
                if (!eval(n.propertyNames, kv, null))
                    return false;
            }
        }
        return true;
    }

    private bool evalInPlace(Node n, ref const Value v, Annotations* a)
    {
        immutable collect = a !is null;
        if (n.hasRef)
        {
            if (n.refTarget is null || !eval(n.refTarget, v, a))
                return false;
        }
        if (n.hasDynamicRef)
        {
            Node target = n.dynamicRefTarget;
            if (n.dynamicRefIsDynamic)
            {
                foreach (i; 0 .. sp)
                {
                    if (auto t = registry.dynamicAnchorTarget(scopeStack[i], n.dynamicRefName))
                    {
                        target = t;
                        break;
                    }
                }
            }
            if (target is null || !eval(target, v, a))
                return false;
        }
        foreach (c; n.allOf)
            if (!eval(c, v, a))
                return false;
        if (n.anyOf.length)
        {
            bool any = false;
            foreach (c; n.anyOf)
            {
                if (collect)
                {
                    Annotations tmp;
                    if (eval(c, v, &tmp))
                    {
                        any = true;
                        a.merge(tmp);
                    }
                }
                else if (eval(c, v, null))
                {
                    any = true;
                    break;
                }
            }
            if (!any)
                return false;
        }
        if (n.oneOf.length)
        {
            int count = 0;
            Annotations winner;
            foreach (c; n.oneOf)
            {
                if (collect)
                {
                    Annotations tmp;
                    if (eval(c, v, &tmp))
                    {
                        count++;
                        winner = tmp;
                    }
                }
                else if (eval(c, v, null))
                    count++;
                if (count > 1)
                    return false;
            }
            if (count != 1)
                return false;
            if (collect)
                a.merge(winner);
        }
        if (n.not !is null && eval(n.not, v, null))
            return false;
        if (n.ifSchema !is null && (collect || n.thenSchema !is null || n.elseSchema !is null))
        {
            Annotations tmp;
            if (eval(n.ifSchema, v, collect ? &tmp : null))
            {
                if (collect)
                    a.merge(tmp);
                if (n.thenSchema !is null && !eval(n.thenSchema, v, a))
                    return false;
            }
            else if (n.elseSchema !is null && !eval(n.elseSchema, v, a))
                return false;
        }
        if (v.kind == Kind.object)
        {
            foreach (ref d; n.dependentSchemas)
                if (v.object.find(d.name) !is null && !eval(d.schema, v, a))
                    return false;
        }
        return true;
    }

    private static bool hasDuplicates(const(Value)[] arr)
    {
        if (arr.length < 2)
            return false;
        if (arr.length <= 8)
        {
            foreach (i; 1 .. arr.length)
                foreach (j; 0 .. i)
                    if (jsonEqual(arr[i], arr[j]))
                        return true;
            return false;
        }
        // Hash chains: head maps a hash to the latest index; next links earlier ones.
        size_t[ulong] head;
        auto next = new size_t[arr.length];
        enum none = size_t.max;
        foreach (i; 0 .. arr.length)
        {
            immutable h = cast(ulong) jsonHash(arr[i]);
            if (auto p = h in head)
            {
                for (size_t j = *p; j != none; j = next[j])
                    if (jsonEqual(arr[i], arr[j]))
                        return true;
                next[i] = *p;
            }
            else
                next[i] = none;
            head[h] = i;
        }
        return false;
    }
}
