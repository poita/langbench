/// The four kinds of git object.
module gitrepo.objecttype;

/// An object's type.
enum ObjectType : ubyte
{
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,
}

/// The type's name as it appears in an object's stored form.
string typeName(ObjectType t) @safe pure nothrow @nogc
{
    final switch (t)
    {
    case ObjectType.commit:
        return "commit";
    case ObjectType.tree:
        return "tree";
    case ObjectType.blob:
        return "blob";
    case ObjectType.tag:
        return "tag";
    }
}

/// Parse a type name; returns false if `name` is not one of the four.
bool tryParseType(scope const(char)[] name, out ObjectType t) @safe pure nothrow @nogc
{
    switch (name)
    {
    case "commit":
        t = ObjectType.commit;
        return true;
    case "tree":
        t = ObjectType.tree;
        return true;
    case "blob":
        t = ObjectType.blob;
        return true;
    case "tag":
        t = ObjectType.tag;
        return true;
    default:
        return false;
    }
}

unittest
{
    ObjectType t;
    assert(tryParseType("tree", t) && t == ObjectType.tree);
    assert(!tryParseType("object", t));
    assert(typeName(ObjectType.tag) == "tag");
}
