#!/usr/bin/env python3
"""Generate the performance-benchmark inputs for the jsonschema problem.

Writes bench/NNN_name.in and bench/NNN_name.out in the same layout as tests/,
so `run_tests.py jsonschema --tests-dir problems/jsonschema/bench` runs them.
Everything is deterministic (fixed seeds). Expected outputs come from the
Python reference implementation.

Each input stays under the spec's 2 MB input limit; the documents are written
as compact JSON so that the byte budget goes to instances rather than
indentation.
"""
import copy
import json
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
sys.path.insert(0, PROBLEM)

import gen_tests  # noqa: E402  (reuses its corpus loaders)

REF = [sys.executable, os.path.join(PROBLEM, "reference", "main.py")]
SIZE_LIMIT = 2_000_000
TARGET = 1_960_000
# Long tier (--long, written to ../bench-long): the same three documents with
# 16x the instances; SPEC.md's input limit is raised to 32 MB for it.
LONG_SIZE_LIMIT = 32_000_000
LONG_TARGET = 31_900_000
LONG = False


def dumps(doc):
    return json.dumps(doc, ensure_ascii=False, separators=(",", ":"))


def fill(schema, make_instance, remotes=None):
    """Append instances from make_instance(i) until the document nears TARGET."""
    doc = {"schema": schema, "tests": []}
    if remotes:
        doc["remotes"] = remotes
    size = len(dumps(doc).encode("utf-8"))
    i = 0
    while True:
        desc, data = make_instance(i)
        case = {"description": desc, "data": data}
        extra = len(dumps(case).encode("utf-8")) + 1
        if size + extra > (LONG_TARGET if LONG else TARGET):
            break
        doc["tests"].append(case)
        size += extra
        i += 1
    return doc


# ---------------------------------------------------------------------------
# Shared vocabulary for synthetic data

WORDS = ("data stream fast tiny core util async http json parse cli config "
         "cache log test web react vue node api server client graph query "
         "schema lint format build bundle router store state hook event "
         "image color date time path file fs crypto hash token auth user "
         "queue worker job task retry pool sql orm model view form input "
         "chart table grid list tree map set vector math stats random").split()
FIRST = ("Ada Alan Barbara Brian Carol Dennis Edsger Frances Grace Guido "
         "Hedy Ken Linus Margaret Niklaus Radia Rob Sophie Tim Yukihiro").split()
LAST = ("Lovelace Turing Liskov Kernighan Shaw Ritchie Dijkstra Allen Hopper "
        "Rossum Lamarr Thompson Torvalds Hamilton Wirth Perlman Pike Wilson "
        "Berners Matsumoto").split()
LICENSES = ["MIT", "ISC", "Apache-2.0", "BSD-3-Clause", "BSD-2-Clause",
            "MPL-2.0", "GPL-3.0-only", "LGPL-2.1-or-later", "Unlicense",
            "(MIT OR Apache-2.0)", "0BSD"]


def pkg_name(r):
    n = "-".join(r.choice(WORDS) for _ in range(r.randint(1, 3)))
    if r.random() < 0.3:
        n = "@" + r.choice(WORDS) + "/" + n
    return n


def semver(r):
    v = "%d.%d.%d" % (r.randint(0, 12), r.randint(0, 30), r.randint(0, 40))
    if r.random() < 0.08:
        v += "-%s.%d" % (r.choice(["alpha", "beta", "rc"]), r.randint(0, 9))
    return v


def range_spec(r):
    k = r.random()
    if k < 0.55:
        return "^" + semver(r)
    if k < 0.75:
        return "~" + semver(r)
    if k < 0.85:
        return ">=%s <%d.0.0" % (semver(r), r.randint(1, 20))
    if k < 0.9:
        return "*"
    if k < 0.95:
        return "workspace:^"
    return semver(r)


def person(r):
    name = r.choice(FIRST) + " " + r.choice(LAST)
    email = name.lower().replace(" ", ".") + "@example.org"
    if r.random() < 0.5:
        return "%s <%s>" % (name, email)
    p = {"name": name, "email": email}
    if r.random() < 0.5:
        p["url"] = "https://%s.dev" % name.split()[0].lower()
    return p


def deps(r, lo, hi):
    return {pkg_name(r): range_spec(r) for _ in range(r.randint(lo, hi))}


# ---------------------------------------------------------------------------
# 001: npm manifests (throughput)

def npm_manifest(r):
    name = pkg_name(r)
    m = {"name": name, "version": semver(r),
         "description": " ".join(r.choice(WORDS) for _ in range(r.randint(4, 14))),
         "keywords": r.sample(WORDS, r.randint(2, 10)),
         "license": r.choice(LICENSES),
         "author": person(r)}
    short = name.split("/")[-1]
    if r.random() < 0.7:
        m["homepage"] = "https://github.com/%s/%s#readme" % (r.choice(WORDS), short)
    if r.random() < 0.7:
        m["repository"] = {"type": "git",
                           "url": "git+https://github.com/%s/%s.git" % (r.choice(WORDS), short)}
    else:
        m["repository"] = "%s/%s" % (r.choice(WORDS), short)
    if r.random() < 0.6:
        m["bugs"] = {"url": "https://github.com/%s/%s/issues" % (r.choice(WORDS), short)}
    if r.random() < 0.4:
        m["contributors"] = [person(r) for _ in range(r.randint(1, 6))]
    if r.random() < 0.3:
        m["funding"] = r.choice([
            "https://github.com/sponsors/" + r.choice(WORDS),
            {"type": "opencollective", "url": "https://opencollective.com/" + short},
            [{"type": "github", "url": "https://github.com/sponsors/x"},
             "https://patreon.com/" + short]])
    m["main"] = r.choice(["index.js", "dist/index.js", "lib/main.js", "./build/cjs/index.cjs"])
    if r.random() < 0.5:
        m["type"] = r.choice(["module", "commonjs"])
    if r.random() < 0.5:
        m["types"] = "./dist/index.d.ts"
    if r.random() < 0.55:
        exp = {".": {"types": "./dist/index.d.ts", "import": "./dist/index.mjs",
                     "require": "./dist/index.cjs", "default": "./dist/index.mjs"}}
        for _ in range(r.randint(0, 5)):
            sub = r.choice(WORDS)
            exp["./" + sub] = r.choice([
                "./dist/%s.js" % sub,
                {"import": "./dist/%s.mjs" % sub, "require": "./dist/%s.cjs" % sub},
                {"node": {"import": "./dist/node/%s.mjs" % sub, "default": "./dist/node/%s.cjs" % sub},
                 "browser": "./dist/browser/%s.js" % sub, "default": "./dist/%s.js" % sub}])
        exp["./package.json"] = "./package.json"
        m["exports"] = exp
    if r.random() < 0.15:
        m["imports"] = {"#internal/*": "./src/internal/*.js",
                        "#dep": {"node": "dep-node-native", "default": "./dep-polyfill.js"}}
    if r.random() < 0.3:
        m["bin"] = r.choice(["./bin/cli.js", {short: "./bin/%s.js" % short,
                                              short + "-dev": "./bin/dev.js"}])
    m["files"] = r.sample(["dist", "lib", "bin", "index.js", "index.d.ts", "src",
                           "README.md", "LICENSE", "*.mjs", "types"], r.randint(1, 6))
    scripts = {"test": r.choice(["jest", "mocha", "vitest run", "node --test", "ava"]),
               "build": r.choice(["tsc -p .", "rollup -c", "esbuild src/index.ts --bundle",
                                  "tsup", "vite build"])}
    for s in r.sample(["lint", "format", "prepare", "prepublishOnly", "pretest",
                       "coverage", "dev", "watch", "clean", "release", "docs",
                       "typecheck", "bench", "start", "postinstall"], r.randint(1, 8)):
        scripts[s] = "%s %s" % (r.choice(["eslint", "prettier", "npm run", "rimraf",
                                          "c8", "node", "tsc"]), r.choice(WORDS))
    m["scripts"] = scripts
    m["dependencies"] = deps(r, 0, 25)
    m["devDependencies"] = deps(r, 2, 40)
    if r.random() < 0.25:
        peers = deps(r, 1, 4)
        m["peerDependencies"] = peers
        m["peerDependenciesMeta"] = {k: {"optional": r.random() < 0.5} for k in peers}
    if r.random() < 0.15:
        m["optionalDependencies"] = deps(r, 1, 3)
    m["engines"] = {"node": ">=%d" % r.choice([14, 16, 18, 20, 22])}
    if r.random() < 0.2:
        m["engines"]["npm"] = ">=%d" % r.choice([7, 8, 9, 10])
    if r.random() < 0.3:
        m["publishConfig"] = {"access": r.choice(["public", "restricted"]),
                              "registry": "https://registry.npmjs.org/"}
    if r.random() < 0.2:
        m["sideEffects"] = r.choice([False, ["*.css", "./dist/polyfill.js"]])
    if r.random() < 0.15:
        m["workspaces"] = r.choice([["packages/*"], {"packages": ["packages/*", "apps/*"]}])
    if r.random() < 0.15:
        m["os"] = r.sample(["darwin", "linux", "win32", "!aix"], 2)
        m["cpu"] = r.sample(["x64", "arm64", "!ia32"], 2)
    if r.random() < 0.2:
        m["packageManager"] = r.choice(["pnpm@9.12.0", "yarn@4.5.0", "npm@10.8.2"])
    # eslintConfig, prettier and similar tool configs refer to external
    # SchemaStore documents that are not bundled, so they are never generated.
    if r.random() < 0.1:
        m["private"] = True
    return m


def npm_break(r, m):
    """Introduce one realistic mistake into a manifest."""
    k = r.randrange(9)
    if k == 0:
        m["version"] = r.randint(1, 9)
    elif k == 1:
        m["name"] = "x" * r.randint(215, 260)
    elif k == 2:
        m["dependencies"][pkg_name(r)] = r.randint(1, 5)
    elif k == 3:
        m["scripts"]["test"] = ["jest", "--ci"]
    elif k == 4:
        m["bugs"] = ["https://example.test/issues"]
    elif k == 5:
        m["keywords"] = " ".join(m["keywords"])
    elif k == 6:
        m["bin"] = 42
    elif k == 7:
        m["engines"] = ["node >= 18"]
    else:
        m["files"] = "dist"
    return m


def bench_npm():
    r = random.Random(20261011)
    schema = gen_tests.npm_schema()

    def make(i):
        m = npm_manifest(r)
        if r.random() < 0.12:
            return "manifest %d (broken)" % i, npm_break(r, m)
        return "manifest %d" % i, m

    return fill(schema, make)


# ---------------------------------------------------------------------------
# 002: OpenAPI 3.1 documents ($dynamicRef, unevaluatedProperties, deep refs)

HTTP_METHODS = ["get", "post", "put", "patch", "delete"]


def oa_schema(r, models, depth=0):
    k = r.random()
    if models and (k < 0.3 or depth > 2):
        return {"$ref": "#/components/schemas/" + r.choice(models)}
    if k < 0.5:
        return r.choice([{"type": "string", "format": r.choice(["date-time", "uuid", "email", "uri"])},
                         {"type": "integer", "format": "int64", "minimum": 0},
                         {"type": "number", "multipleOf": 0.01},
                         {"type": "string", "enum": r.sample(WORDS, 4)},
                         {"type": "boolean", "default": False},
                         {"type": ["string", "null"], "maxLength": 255}])
    if k < 0.7:
        return {"type": "array", "items": oa_schema(r, models, depth + 1),
                "maxItems": r.randint(10, 500)}
    if k < 0.8 and models:
        return {"oneOf": [{"$ref": "#/components/schemas/" + m}
                          for m in r.sample(models, min(len(models), 3))],
                "discriminator": {"propertyName": "kind"}}
    props = {w: oa_schema(r, models, depth + 1) for w in r.sample(WORDS, r.randint(2, 9))}
    obj = {"type": "object", "properties": props,
           "required": list(props)[:r.randint(0, len(props))]}
    if r.random() < 0.4:
        obj["additionalProperties"] = False
    elif r.random() < 0.3:
        obj["patternProperties"] = {"^x-": {"type": "string"}}
    if r.random() < 0.2:
        obj["allOf"] = [{"$ref": "#/components/schemas/" + r.choice(models)}] if models else []
    if r.random() < 0.15:
        obj["if"] = {"properties": {"kind": {"const": r.choice(WORDS)}}}
        obj["then"] = {"required": [r.choice(list(props))]}
    if r.random() < 0.3:
        obj["examples"] = [{k: None for k in list(props)[:2]}]
    return obj


def oa_param(r):
    loc = r.choice(["query", "query", "header", "path"])
    p = {"name": r.choice(WORDS) + ("Id" if loc == "path" else ""), "in": loc,
         "description": "The %s %s." % (r.choice(WORDS), r.choice(WORDS)),
         "required": loc == "path" or r.random() < 0.3,
         "schema": r.choice([{"type": "string"}, {"type": "integer", "minimum": 1, "maximum": 1000},
                             {"type": "array", "items": {"type": "string"}}])}
    if loc == "query" and r.random() < 0.3:
        p["style"] = "form"
        p["explode"] = r.random() < 0.5
    return p


def oa_response(r, models):
    resp = {"description": "%s %s" % (r.choice(WORDS).capitalize(), r.choice(WORDS))}
    if r.random() < 0.85:
        mt = {"schema": oa_schema(r, models)}
        if r.random() < 0.3:
            mt["examples"] = {"sample": {"summary": "A sample", "value": {"id": r.randint(1, 999)}}}
        resp["content"] = {"application/json": mt}
    if r.random() < 0.3:
        resp["headers"] = {"X-Rate-Limit": {"description": "Calls per hour",
                                            "schema": {"type": "integer"}}}
    if r.random() < 0.15:
        resp["links"] = {"next": {"operationId": "op" + str(r.randint(1, 100)),
                                  "parameters": {"cursor": "$response.body#/next"}}}
    return resp


def oa_operation(r, models, op_id, tags):
    op = {"operationId": op_id, "summary": " ".join(r.choice(WORDS) for _ in range(4)),
          "tags": r.sample(tags, r.randint(1, 2)),
          "parameters": [oa_param(r) for _ in range(r.randint(0, 5))]}
    if r.random() < 0.4:
        op["requestBody"] = {"required": True, "content": {
            "application/json": {"schema": oa_schema(r, models)}}}
    responses = {"200": oa_response(r, models)}
    for code in r.sample(["201", "204", "400", "401", "403", "404", "409", "422", "500", "default"],
                         r.randint(1, 4)):
        responses[code] = (oa_response(r, models) if r.random() < 0.6
                           else {"$ref": "#/components/responses/Error"})
    op["responses"] = responses
    if r.random() < 0.3:
        op["security"] = [{"bearerAuth": []}]
    if r.random() < 0.05:
        op["deprecated"] = True
    if r.random() < 0.08:
        op["callbacks"] = {"onEvent": {"{$request.body#/callbackUrl}": {
            "post": {"requestBody": {"content": {"application/json": {"schema": oa_schema(r, models)}}},
                     "responses": {"200": {"description": "ok"}}}}}}
    return op


def openapi_doc(r, n_paths):
    models = ["Model%s%d" % (r.choice(WORDS).capitalize(), i) for i in range(r.randint(30, 80))]
    tags = r.sample(WORDS, 6)
    comps = {"schemas": {}, "responses": {"Error": {
        "description": "An error", "content": {"application/json": {"schema": {
            "type": "object", "required": ["code", "message"],
            "properties": {"code": {"type": "integer"}, "message": {"type": "string"}}}}}}},
        "securitySchemes": {"bearerAuth": {"type": "http", "scheme": "bearer", "bearerFormat": "JWT"},
                            "apiKey": {"type": "apiKey", "in": "header", "name": "X-API-Key"}}}
    for i, m in enumerate(models):
        comps["schemas"][m] = oa_schema(r, models[:i]) if i else {
            "type": "object", "properties": {"id": {"type": "string"}}}
        comps["schemas"][m]["description"] = "The %s model." % m
    paths = {}
    n_op = 0
    for _ in range(n_paths):
        p = "/" + "/".join(r.choice(WORDS) for _ in range(r.randint(1, 3)))
        if r.random() < 0.5:
            p += "/{%sId}" % r.choice(WORDS)
        item = {}
        for meth in r.sample(HTTP_METHODS, r.randint(1, 4)):
            n_op += 1
            item[meth] = oa_operation(r, models, "op%d" % n_op, tags)
        paths[p] = item
    doc = {"openapi": r.choice(["3.1.0", "3.1.1"]),
           "info": {"title": "%s API" % r.choice(WORDS).capitalize(), "version": semver(r),
                    "description": "Synthetic API.", "license": {"name": "MIT", "identifier": "MIT"},
                    "contact": {"name": "API team", "email": "api@example.org"}},
           "servers": [{"url": "https://{env}.example.org/v1",
                        "variables": {"env": {"default": "api", "enum": ["api", "staging"]}}}],
           "tags": [{"name": t, "description": "%s operations" % t} for t in tags],
           "paths": paths, "components": comps}
    if r.random() < 0.3:
        doc["webhooks"] = {"newThing": {"post": oa_operation(r, models, "hook", tags)}}
    return doc


def openapi_break(r, doc):
    k = r.randrange(7)
    if k == 0:
        doc["openapi"] = "3.0.3"
    elif k == 1:
        del doc["info"]
    elif k == 2:
        p = next(iter(doc["paths"]))
        doc["paths"][p.lstrip("/")] = doc["paths"].pop(p)
    elif k == 3:
        p = r.choice(list(doc["paths"]))
        op = next(iter(doc["paths"][p].values()))
        op["responses"]["twohundred"] = op["responses"].pop("200")
    elif k == 4:
        p = r.choice(list(doc["paths"]))
        op = next(iter(doc["paths"][p].values()))
        op["parameters"].append({"name": "q", "in": "body", "schema": {"type": "string"}})
    elif k == 5:
        name = r.choice(list(doc["components"]["schemas"]))
        doc["components"]["schemas"][name]["type"] = "strng"
    else:
        name = r.choice(list(doc["components"]["schemas"]))
        doc["components"]["schemas"][name]["required"] = "id"
    return doc


def bench_openapi():
    """OpenAPI 3.1 documents validated with full Schema Object checking.

    The schema is the equivalent of the published OAS 3.1 "schema-base"
    document: it refers to the OAS document schema and redefines the dynamic
    anchor "meta" as the 2020-12 meta-schema, so every Schema Object inside a
    document is itself validated against the meta-schema through $dynamicRef.
    """
    r = random.Random(31)
    oas = gen_tests.read_json(os.path.join(gen_tests.CORPUS, "openapi", "oas31-schema.json"))
    schema = {"$schema": "https://json-schema.org/draft/2020-12/schema",
              "$id": "https://spec.openapis.org/oas/3.1/schema-base/2022-10-07",
              "$ref": oas["$id"],
              "$defs": {"schema": {"$dynamicAnchor": "meta",
                                   "$ref": "https://json-schema.org/draft/2020-12/schema"}}}
    remotes = dict(gen_tests.METASCHEMA_REMOTES)
    remotes[oas["$id"]] = oas
    examples = os.path.join(gen_tests.CORPUS, "openapi", "examples")
    real = sorted(f for f in os.listdir(examples) if f.endswith(".json"))

    def make(i):
        if i < len(real):
            d = gen_tests.read_json(os.path.join(examples, real[i]))
            d["openapi"] = "3.1.0"
            return real[i], d
        doc = openapi_doc(r, r.randint(5, 30))
        if r.random() < 0.2:
            return "api %d (broken)" % i, openapi_break(r, doc)
        return "api %d" % i, doc

    return fill(schema, make, remotes)


# ---------------------------------------------------------------------------
# 003: order records against a hand-written schema using most keywords

ORDER_SCHEMA = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$id": "https://shop.example/schemas/order.json",
    "title": "Order",
    "type": "object",
    "$ref": "#/$defs/timestamped",
    "required": ["orderId", "customer", "lines", "currency", "total", "status"],
    "properties": {
        "orderId": {"type": "string", "pattern": "^ORD-[0-9]{4}-[A-Z0-9]{8}$"},
        "customer": {"$ref": "customer.json"},
        "currency": {"enum": ["USD", "EUR", "GBP", "JPY", "AUD", "CAD"]},
        "lines": {"type": "array", "minItems": 1, "maxItems": 200,
                  "items": {"$ref": "#/$defs/line"}},
        "total": {"$ref": "#/$defs/money"},
        "discounts": {"type": "array", "uniqueItems": True,
                      "items": {"type": "string", "pattern": "^[A-Z][A-Z0-9]{3,11}$"}},
        "status": {"enum": ["pending", "paid", "shipped", "delivered", "cancelled", "refunded"]},
        "shipping": {"$ref": "#/$defs/address"},
        "billing": {"$ref": "#/$defs/address"},
        "payment": {"oneOf": [
            {"$ref": "#/$defs/cardPayment"},
            {"$ref": "#/$defs/bankPayment"},
            {"$ref": "#/$defs/walletPayment"}]},
        "tags": {"type": "array", "uniqueItems": True, "maxItems": 20,
                 "items": {"type": "string", "minLength": 1, "maxLength": 32}},
        "metadata": {"type": "object", "maxProperties": 30,
                     "propertyNames": {"pattern": "^[a-z][a-z0-9_]{0,39}$"},
                     "additionalProperties": {"type": ["string", "number", "boolean", "null"]}},
        "history": {"type": "array",
                    "prefixItems": [{"$ref": "#/$defs/event"}],
                    "items": {"$ref": "#/$defs/event"},
                    "contains": {"type": "object",
                                 "properties": {"kind": {"const": "created"}},
                                 "required": ["kind"]},
                    "maxContains": 1}
    },
    "patternProperties": {"^x-[a-z][a-z-]*$": True},
    "dependentRequired": {"shipping": ["billing"]},
    "dependentSchemas": {"payment": {"properties": {"status": {"not": {"const": "pending"}}}}},
    "allOf": [
        {"if": {"properties": {"status": {"enum": ["shipped", "delivered"]}},
                "required": ["status"]},
         "then": {"required": ["shipping", "trackingNumber"]}},
        {"if": {"properties": {"currency": {"const": "JPY"}}},
         "then": {"properties": {"total": {"multipleOf": 1}}},
         "else": {"properties": {"total": {"multipleOf": 0.01}}}}
    ],
    "unevaluatedProperties": False,
    "$defs": {
        "timestamped": {
            "properties": {
                "createdAt": {"type": "string",
                              "pattern": "^\\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\\d|3[01])T([01]\\d|2[0-3]):[0-5]\\d:[0-5]\\d(\\.\\d{1,6})?(Z|[+-]\\d{2}:\\d{2})$"},
                "updatedAt": {"$ref": "#/$defs/timestamped/properties/createdAt"},
                "trackingNumber": {"type": "string", "pattern": "^(1Z[0-9A-Z]{16}|\\d{12}|\\d{20}|[A-Z]{2}\\d{9}[A-Z]{2})$"}
            }
        },
        "money": {"type": "number", "minimum": 0, "exclusiveMaximum": 1e9},
        "line": {
            "type": "object",
            "required": ["sku", "quantity", "unitPrice"],
            "properties": {
                "sku": {"type": "string", "pattern": "^[A-Z]{3}-\\d{5}(-[A-Z0-9]{2,4})?$"},
                "name": {"type": "string", "maxLength": 120},
                "quantity": {"type": "integer", "minimum": 1, "maximum": 10000},
                "unitPrice": {"$ref": "#/$defs/money", "multipleOf": 0.01},
                "taxRate": {"type": "number", "minimum": 0, "maximum": 0.5, "multipleOf": 0.0001},
                "weightKg": {"type": "number", "exclusiveMinimum": 0, "multipleOf": 0.001},
                "attributes": {"type": "object",
                               "patternProperties": {
                                   "^(color|colour)$": {"type": "string"},
                                   "^size(_[a-z]{2})?$": {"enum": ["XS", "S", "M", "L", "XL", "XXL"]},
                                   "^dim_[xyz]_cm$": {"type": "number", "minimum": 0}},
                               "additionalProperties": False},
                "giftWrap": {"type": "boolean"}
            },
            "additionalProperties": False
        },
        "address": {
            "type": "object",
            "required": ["line1", "city", "country"],
            "properties": {
                "name": {"type": "string"},
                "line1": {"type": "string", "minLength": 1, "maxLength": 100},
                "line2": {"type": "string", "maxLength": 100},
                "city": {"type": "string", "minLength": 1},
                "region": {"type": "string"},
                "postcode": {"type": "string"},
                "country": {"type": "string", "pattern": "^[A-Z]{2}$"}
            },
            "allOf": [
                {"if": {"properties": {"country": {"const": "US"}}},
                 "then": {"required": ["region", "postcode"],
                          "properties": {"postcode": {"pattern": "^\\d{5}(-\\d{4})?$"}}}},
                {"if": {"properties": {"country": {"const": "GB"}}},
                 "then": {"properties": {"postcode": {"pattern": "^[A-Z]{1,2}\\d[A-Z\\d]? ?\\d[A-Z]{2}$"}}}},
                {"if": {"properties": {"country": {"enum": ["DE", "FR"]}}},
                 "then": {"properties": {"postcode": {"pattern": "^\\d{5}$"}}}}
            ],
            "unevaluatedProperties": False
        },
        "cardPayment": {
            "type": "object", "required": ["method", "last4", "brand"],
            "properties": {"method": {"const": "card"},
                           "brand": {"enum": ["visa", "mastercard", "amex", "discover"]},
                           "last4": {"type": "string", "pattern": "^\\d{4}$"},
                           "expires": {"type": "string", "pattern": "^(0[1-9]|1[0-2])/\\d{2}$"}},
            "additionalProperties": False},
        "bankPayment": {
            "type": "object", "required": ["method", "iban"],
            "properties": {"method": {"const": "bank"},
                           "iban": {"type": "string", "pattern": "^[A-Z]{2}\\d{2}[A-Z0-9]{11,30}$"},
                           "bic": {"type": "string", "pattern": "^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$"}},
            "additionalProperties": False},
        "walletPayment": {
            "type": "object", "required": ["method", "provider"],
            "properties": {"method": {"const": "wallet"},
                           "provider": {"enum": ["applepay", "googlepay", "paypal"]},
                           "account": {"type": "string", "format": "email",
                                       "pattern": "^[^@\\s]+@[^@\\s]+\\.[a-z]{2,}$"}},
            "additionalProperties": False},
        "event": {
            "type": "object", "required": ["kind", "at"],
            "properties": {"kind": {"enum": ["created", "paid", "packed", "shipped",
                                             "delivered", "note", "refund"]},
                           "at": {"$ref": "#/$defs/timestamped/properties/createdAt"},
                           "by": {"type": "string"},
                           "note": {"type": "string", "maxLength": 500}},
            "additionalProperties": False}
    }
}

CUSTOMER_SCHEMA = {
    "$id": "https://shop.example/schemas/customer.json",
    "type": "object",
    "required": ["id", "email"],
    "properties": {
        "id": {"type": "string", "pattern": "^cus_[A-Za-z0-9]{14}$"},
        "email": {"type": "string", "pattern": "^[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}$"},
        "name": {"type": "string", "minLength": 1, "maxLength": 80},
        "phone": {"type": "string", "pattern": "^\\+[1-9]\\d{6,14}$"},
        "loyalty": {"type": "object",
                    "properties": {"tier": {"enum": ["bronze", "silver", "gold", "platinum"]},
                                   "points": {"type": "integer", "minimum": 0}},
                    "required": ["tier"]}
    },
    "additionalProperties": False
}

ALNUM = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
COUNTRIES = ["US", "GB", "DE", "FR", "AU", "JP", "CA", "NZ"]


def ts(r):
    return "2026-%02d-%02dT%02d:%02d:%02d%s%s" % (
        r.randint(1, 12), r.randint(1, 28), r.randint(0, 23), r.randint(0, 59), r.randint(0, 59),
        "" if r.random() < 0.6 else ".%03d" % r.randint(0, 999),
        "Z" if r.random() < 0.7 else "+%02d:00" % r.randint(0, 11))


def money(r, lo, hi, jpy=False):
    cents = r.randint(lo * 100, hi * 100)
    if jpy:
        return cents // 100
    # Python prints these floats back as their shortest decimal literal,
    # so the JSON carries the exact two-decimal amount.
    return float("%d.%02d" % divmod(cents, 100))


def address(r):
    c = r.choice(COUNTRIES)
    a = {"name": r.choice(FIRST) + " " + r.choice(LAST),
         "line1": "%d %s Street" % (r.randint(1, 999), r.choice(LAST)),
         "city": r.choice(WORDS).capitalize() + "ville", "country": c}
    if r.random() < 0.3:
        a["line2"] = "Unit %d" % r.randint(1, 99)
    if c == "US":
        a["region"] = r.choice(["CA", "NY", "TX", "WA"])
        a["postcode"] = "%05d" % r.randint(10000, 99999) + ("" if r.random() < 0.7 else "-%04d" % r.randint(0, 9999))
    elif c == "GB":
        a["postcode"] = "%s%d %d%s" % (r.choice(["SW", "N", "EC", "M"]), r.randint(1, 9),
                                       r.randint(0, 9), "".join(r.choice("ABDEFGHJLNPQRSTUWXYZ") for _ in range(2)))
    elif c in ("DE", "FR"):
        a["postcode"] = "%05d" % r.randint(1000, 99999)
    else:
        a["postcode"] = str(r.randint(1000, 9999))
    return a


def order(r, i):
    currency = r.choice(["USD", "EUR", "GBP", "JPY", "AUD", "CAD"])
    jpy = currency == "JPY"
    status = r.choice(["pending", "paid", "paid", "shipped", "delivered", "cancelled", "refunded"])
    lines = []
    for _ in range(r.randint(1, 12)):
        ln = {"sku": "%s-%05d" % ("".join(r.choice(ALNUM[:26]) for _ in range(3)), r.randint(0, 99999)),
              "name": " ".join(r.choice(WORDS) for _ in range(r.randint(1, 2))),
              "quantity": r.randint(1, 20),
              "unitPrice": money(r, 1, 900)}
        if r.random() < 0.3:
            ln["sku"] += "-" + "".join(r.choice(ALNUM) for _ in range(r.randint(2, 4)))
        if r.random() < 0.6:
            ln["taxRate"] = float("0.%04d" % r.choice([0, 500, 725, 875, 1000, 1500, 2000, 2100]))
        if r.random() < 0.5:
            ln["weightKg"] = float("%d.%03d" % (r.randint(0, 30), r.randint(1, 999)))
        if r.random() < 0.4:
            attrs = {r.choice(["color", "colour"]): r.choice(["red", "blue", "black"]),
                     r.choice(["size", "size_eu", "size_us"]): r.choice(["S", "M", "L", "XL"])}
            if r.random() < 0.4:
                attrs["dim_x_cm"] = r.randint(1, 200)
            ln["attributes"] = attrs
        if r.random() < 0.1:
            ln["giftWrap"] = True
        lines.append(ln)
    total = money(r, 5, 20000, jpy)
    cust = {"id": "cus_" + "".join(r.choice(ALNUM + "abcdefghijklmnopqrstuvwxyz") for _ in range(14)),
            "email": "%s.%s@%s.example" % (r.choice(FIRST).lower(), r.choice(LAST).lower(), r.choice(WORDS))}
    if r.random() < 0.7:
        cust["name"] = r.choice(FIRST) + " " + r.choice(LAST)
    if r.random() < 0.5:
        cust["phone"] = "+%d%d" % (r.randint(1, 99), r.randint(1000000, 999999999))
    if r.random() < 0.4:
        cust["loyalty"] = {"tier": r.choice(["bronze", "silver", "gold", "platinum"]),
                           "points": r.randint(0, 50000)}
    o = {"orderId": "ORD-2026-" + "".join(r.choice(ALNUM) for _ in range(8)),
         "customer": cust, "currency": currency, "lines": lines, "total": total,
         "status": status, "createdAt": ts(r), "updatedAt": ts(r)}
    if status != "pending":
        o["payment"] = r.choice([
            {"method": "card", "brand": r.choice(["visa", "mastercard", "amex"]),
             "last4": "%04d" % r.randint(0, 9999), "expires": "%02d/%02d" % (r.randint(1, 12), r.randint(26, 32))},
            {"method": "bank", "iban": "DE%02d%s" % (r.randint(10, 99), "".join(str(r.randint(0, 9)) for _ in range(18))),
             "bic": "DEUTDEFF" + ("" if r.random() < 0.5 else "500")},
            {"method": "wallet", "provider": r.choice(["applepay", "googlepay", "paypal"]),
             "account": "%s@pay.example" % r.choice(WORDS)}])
    if status in ("shipped", "delivered") or r.random() < 0.3:
        o["shipping"] = address(r)
        o["billing"] = address(r) if r.random() < 0.4 else copy.deepcopy(o["shipping"])
    if status in ("shipped", "delivered"):
        o["trackingNumber"] = r.choice([
            "1Z" + "".join(r.choice(ALNUM) for _ in range(16)),
            "".join(str(r.randint(0, 9)) for _ in range(12)),
            "LX%09dUS" % r.randint(0, 999999999)])
    if r.random() < 0.3:
        o["discounts"] = list(dict.fromkeys(
            "".join([r.choice(ALNUM[:26])] + [r.choice(ALNUM) for _ in range(r.randint(3, 9))])
            for _ in range(r.randint(1, 3))))
    if r.random() < 0.5:
        o["tags"] = list(dict.fromkeys(r.choice(WORDS) for _ in range(r.randint(1, 8))))
    if r.random() < 0.4:
        o["metadata"] = {"%s_%s" % (r.choice(WORDS), r.choice(WORDS)): r.choice(
            ["web", 3, True, None, "mobile"]) for _ in range(r.randint(1, 8))}
    hist = [{"kind": "created", "at": ts(r), "by": "system"}]
    for _ in range(r.randint(0, 8)):
        e = {"kind": r.choice(["paid", "packed", "shipped", "delivered", "note"]), "at": ts(r)}
        if e["kind"] == "note":
            e["note"] = " ".join(r.choice(WORDS) for _ in range(r.randint(2, 8)))
        hist.append(e)
    o["history"] = hist
    if r.random() < 0.1:
        o["x-source-system"] = r.choice(["pos", "web", "api"])
    return o


def order_break(r, o):
    k = r.randrange(12)
    if k == 0:
        o["orderId"] = o["orderId"].lower()
    elif k == 1:
        o["lines"][0]["unitPrice"] = float("19.999")
    elif k == 2:
        o["lines"][-1]["quantity"] = 0
    elif k == 3:
        o["customer"]["email"] = "not-an-email"
    elif k == 4:
        o["status"] = "shipped"
        o.pop("trackingNumber", None)
    elif k == 5:
        o["unexpected"] = True
    elif k == 6:
        o["tags"] = ["dup", "dup"]
    elif k == 7:
        o["history"].append({"kind": "created", "at": ts(r)})
    elif k == 8:
        o["createdAt"] = "2026-13-01T00:00:00Z"
    elif k == 9:
        o["shipping"] = {"line1": "1 Main St", "city": "Springfield", "country": "US"}
        o["billing"] = o["shipping"]
    elif k == 10:
        o["lines"][0]["attributes"] = {"size": "XXXL"}
    else:
        o["status"] = "pending"
        o["payment"] = {"method": "card", "brand": "visa", "last4": "1234"}
    return o


def bench_orders():
    r = random.Random(7)

    def make(i):
        o = order(r, i)
        if r.random() < 0.15:
            return "order %d (broken)" % i, order_break(r, o)
        return "order %d" % i, o

    remotes = {CUSTOMER_SCHEMA["$id"]: CUSTOMER_SCHEMA}
    return fill(ORDER_SCHEMA, make, remotes)


# ---------------------------------------------------------------------------

BENCHES = [
    ("001_npm_manifests_throughput", bench_npm),
    ("002_openapi31_documents_full_schema_dialect", bench_openapi),
    ("003_order_records_mixed_keywords", bench_orders),
]


def main():
    global LONG
    LONG = "--long" in sys.argv[1:]
    out_dir = os.path.join(os.path.dirname(HERE), "bench-long") if LONG else HERE
    os.makedirs(out_dir, exist_ok=True)
    only = set(a for a in sys.argv[1:] if not a.startswith("--"))
    for stem, build in BENCHES:
        if only and stem not in only:
            continue
        doc = build()
        text = dumps(doc) + "\n"
        data = text.encode("utf-8")
        if len(data) > (LONG_SIZE_LIMIT if LONG else SIZE_LIMIT):
            raise SystemExit("%s is %d bytes, over the limit" % (stem, len(data)))
        in_path = os.path.join(out_dir, stem + ".in")
        with open(in_path, "wb") as f:
            f.write(data)
        proc = subprocess.run(REF, stdin=open(in_path, "rb"), capture_output=True)
        if proc.returncode != 0:
            raise SystemExit("reference failed on %s:\n%s" %
                             (stem, proc.stderr.decode("utf-8", "replace")))
        lines = proc.stdout.decode("utf-8").split()
        if len(lines) != len(doc["tests"]):
            raise SystemExit("%s: %d lines for %d tests" % (stem, len(lines), len(doc["tests"])))
        with open(os.path.join(out_dir, stem + ".out"), "w", encoding="utf-8") as f:
            f.write("".join(line + "\n" for line in lines))
        print("%s: %d bytes, %d instances, %d invalid" %
              (stem, len(data), len(lines), lines.count("invalid")))


if __name__ == "__main__":
    main()
