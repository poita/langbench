/// Shared helpers for the unit tests.
module helpers;

import canonjson;

/// Canonical form of `json` as a string, or "invalid".
string canon(const(char)[] json)
{
    ubyte[] out_;
    if (!tryCanonicalize(cast(const(ubyte)[]) json, out_))
        return "invalid";
    return cast(string) out_.idup;
}

/// Canonical form of raw bytes, or "invalid".
string canonBytes(const(ubyte)[] json)
{
    ubyte[] out_;
    if (!tryCanonicalize(json, out_))
        return "invalid";
    return cast(string) out_.idup;
}
