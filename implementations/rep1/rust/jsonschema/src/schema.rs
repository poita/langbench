//! Schema compilation: indexing and keyword decoding.
//!
//! [`Schema::compile`] walks the root schema and every remote document once
//! (SPEC §6.2), recording each schema object's base URI, filling the
//! registries of resources, JSON-Pointer locations, anchors and dynamic
//! anchors, decoding keywords into a [`Node`] and compiling patterns. Every
//! `$ref` / `$dynamicRef` is resolved to a node id in a second step, so
//! validation never touches a URI.

use crate::json::{Json, Object};
use crate::number::Number;
use crate::regex::{Regex, RegexError};
use crate::uri;
use std::collections::{HashMap, HashSet};
use std::fmt;
use std::rc::Rc;

/// Index of a node in a [`Schema`]'s arena.
pub(crate) type NodeId = usize;

/// An error found while compiling a schema.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
    /// A `pattern` or `patternProperties` key is not a supported regular
    /// expression.
    InvalidPattern {
        /// The offending pattern.
        pattern: String,
        /// The compiler's complaint.
        source: RegexError,
    },
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::InvalidPattern { pattern, source } => {
                write!(f, "pattern {pattern:?}: {source}")
            }
        }
    }
}

impl std::error::Error for Error {}

// Bits of `Keywords::types`.
pub(crate) const T_NULL: u8 = 1;
pub(crate) const T_BOOLEAN: u8 = 2;
pub(crate) const T_OBJECT: u8 = 4;
pub(crate) const T_ARRAY: u8 = 8;
pub(crate) const T_NUMBER: u8 = 16;
pub(crate) const T_STRING: u8 = 32;
pub(crate) const T_INTEGER: u8 = 64;

/// A count bound (`minLength`, `maxItems`, ...), kept both exactly and, when
/// possible, as a `usize`.
#[derive(Clone, Debug)]
pub(crate) struct Limit {
    exact: Number,
    small: Option<usize>,
}

impl Limit {
    fn new(n: &Number) -> Limit {
        Limit {
            small: n.to_usize(),
            exact: n.clone(),
        }
    }

    /// `len <= limit`
    pub(crate) fn allows_at_most(&self, len: usize) -> bool {
        match self.small {
            Some(s) => len <= s,
            None => Number::from_u64(len as u64) <= self.exact,
        }
    }

    /// `len >= limit`
    pub(crate) fn allows_at_least(&self, len: usize) -> bool {
        match self.small {
            Some(s) => len >= s,
            None => Number::from_u64(len as u64) >= self.exact,
        }
    }
}

/// A resolved `$dynamicRef`.
#[derive(Clone, Debug, Default)]
pub(crate) struct DynamicRef {
    /// What the reference resolves to when it is not dynamic (or when no
    /// scope entry provides the anchor).
    pub(crate) target: Option<NodeId>,
    /// Index into `Schema::dynamic_tables` when the reference names a
    /// dynamic anchor.
    pub(crate) table: Option<usize>,
}

/// The decoded keywords of one schema object.
#[derive(Default, Debug)]
pub(crate) struct Keywords {
    pub(crate) types: Option<u8>,
    pub(crate) enum_values: Option<Vec<Json>>,
    pub(crate) const_value: Option<Json>,

    pub(crate) multiple_of: Option<Number>,
    pub(crate) maximum: Option<Number>,
    pub(crate) minimum: Option<Number>,
    pub(crate) exclusive_maximum: Option<Number>,
    pub(crate) exclusive_minimum: Option<Number>,

    pub(crate) max_length: Option<Limit>,
    pub(crate) min_length: Option<Limit>,
    pub(crate) pattern: Option<Rc<Regex>>,

    pub(crate) max_items: Option<Limit>,
    pub(crate) min_items: Option<Limit>,
    pub(crate) unique_items: bool,
    pub(crate) prefix_items: Option<Vec<NodeId>>,
    pub(crate) items: Option<NodeId>,
    pub(crate) contains: Option<NodeId>,
    pub(crate) min_contains: Option<Limit>,
    pub(crate) max_contains: Option<Limit>,

    pub(crate) max_properties: Option<Limit>,
    pub(crate) min_properties: Option<Limit>,
    pub(crate) required: Vec<String>,
    pub(crate) dependent_required: Vec<(String, Vec<String>)>,
    pub(crate) properties: Vec<(String, NodeId)>,
    pub(crate) property_index: HashMap<String, usize>,
    pub(crate) pattern_properties: Vec<(Rc<Regex>, NodeId)>,
    pub(crate) additional_properties: Option<NodeId>,
    pub(crate) property_names: Option<NodeId>,
    pub(crate) dependent_schemas: Vec<(String, NodeId)>,

    pub(crate) all_of: Option<Vec<NodeId>>,
    pub(crate) any_of: Option<Vec<NodeId>>,
    pub(crate) one_of: Option<Vec<NodeId>>,
    pub(crate) not: Option<NodeId>,
    pub(crate) if_: Option<NodeId>,
    pub(crate) then_: Option<NodeId>,
    pub(crate) else_: Option<NodeId>,
    pub(crate) unevaluated_items: Option<NodeId>,
    pub(crate) unevaluated_properties: Option<NodeId>,

    /// `$ref`: `Some(None)` is a reference that did not resolve.
    pub(crate) reference: Option<Option<NodeId>>,
    pub(crate) dynamic_reference: Option<DynamicRef>,
}

/// One schema object (or boolean schema).
#[derive(Debug)]
pub(crate) struct Node {
    /// Interned base URI in force at this schema object.
    pub(crate) base: u32,
    /// `Some(b)` for the boolean schemas.
    pub(crate) constant: Option<bool>,
    pub(crate) kw: Keywords,
    /// Whether an `unevaluated*` keyword needs annotations from siblings.
    pub(crate) needs_annotations: bool,
}

/// A compiled schema, ready to validate instances.
///
/// ```
/// use jsonschema::{json, Schema};
///
/// let schema = Schema::compile(&json::parse(r#"{"type": "integer", "minimum": 1}"#).unwrap()).unwrap();
/// assert!(schema.is_valid(&json::parse("3").unwrap()));
/// assert!(!schema.is_valid(&json::parse("0").unwrap()));
/// ```
#[derive(Debug)]
pub struct Schema {
    pub(crate) nodes: Vec<Node>,
    pub(crate) root: NodeId,
    /// For each dynamic-anchor name: base URI id → node.
    pub(crate) dynamic_tables: Vec<HashMap<u32, NodeId>>,
}

/// Configures a [`Schema`] with remote documents.
///
/// ```
/// use jsonschema::{json, Schema};
///
/// let remote = json::parse(r#"{"type": "string"}"#).unwrap();
/// let root = json::parse(r#"{"$ref": "http://example.test/s.json"}"#).unwrap();
/// let schema = Schema::builder()
///     .remote("http://example.test/s.json", &remote)
///     .build(&root)
///     .unwrap();
/// assert!(schema.is_valid(&json::parse(r#""x""#).unwrap()));
/// assert!(!schema.is_valid(&json::parse("1").unwrap()));
/// ```
#[derive(Default)]
pub struct SchemaBuilder<'a> {
    remotes: Vec<(&'a str, &'a Json)>,
}

impl<'a> SchemaBuilder<'a> {
    /// Adds a document that references may point at, under its retrieval URI.
    pub fn remote(mut self, uri: &'a str, document: &'a Json) -> Self {
        self.remotes.push((uri, document));
        self
    }

    /// Compiles `root` (retrieval URI `""`) together with the remotes.
    pub fn build(self, root: &Json) -> Result<Schema, Error> {
        let mut c = Compiler::default();
        let root_id = c.document("", root)?;
        for (uri, doc) in &self.remotes {
            c.document(uri, doc)?;
        }
        Ok(c.finish(root_id))
    }
}

impl Schema {
    /// Compiles a schema with no remote documents.
    pub fn compile(root: &Json) -> Result<Schema, Error> {
        SchemaBuilder::default().build(root)
    }

    /// Starts a builder, to supply remote documents.
    pub fn builder<'a>() -> SchemaBuilder<'a> {
        SchemaBuilder::default()
    }
}

// ---------------------------------------------------------------------------
// Compiler
// ---------------------------------------------------------------------------

/// A resource (a base URI alias set) on the walk stack.
struct Frame {
    /// Every URI the resource is registered under; `aliases[0]` is primary.
    aliases: Vec<String>,
    /// Length of the pointer path at the resource's root.
    path_len: usize,
}

struct Walk {
    path: String,
    frames: Vec<Frame>,
    /// Interned id of the innermost base URI.
    base: u32,
}

enum Pending {
    Ref(NodeId, String),
    Dynamic(NodeId, String),
}

#[derive(Default)]
struct Compiler {
    nodes: Vec<Node>,
    base_ids: HashMap<String, u32>,
    resources: HashMap<String, NodeId>,
    pointers: HashMap<(String, String), NodeId>,
    anchors: HashMap<(String, String), NodeId>,
    /// `(document URI, name)` pairs that are dynamic anchors.
    dynamic_set: HashSet<(String, String)>,
    /// name → (primary base id → node)
    dynamic_by_name: HashMap<String, HashMap<u32, NodeId>>,
    pending: Vec<Pending>,
    patterns: HashMap<String, Rc<Regex>>,
}

fn kw_u8(name: &str) -> Option<u8> {
    Some(match name {
        "null" => T_NULL,
        "boolean" => T_BOOLEAN,
        "object" => T_OBJECT,
        "array" => T_ARRAY,
        "number" => T_NUMBER,
        "string" => T_STRING,
        "integer" => T_INTEGER,
        _ => return None,
    })
}

impl Compiler {
    fn intern(&mut self, uri: &str) -> u32 {
        if let Some(&id) = self.base_ids.get(uri) {
            return id;
        }
        let id = self.base_ids.len() as u32;
        self.base_ids.insert(uri.to_string(), id);
        id
    }

    fn pattern(&mut self, p: &str) -> Result<Rc<Regex>, Error> {
        if let Some(r) = self.patterns.get(p) {
            return Ok(r.clone());
        }
        let re = Rc::new(Regex::new(p).map_err(|source| Error::InvalidPattern {
            pattern: p.to_string(),
            source,
        })?);
        self.patterns.insert(p.to_string(), re.clone());
        Ok(re)
    }

    /// Indexes and compiles one document.
    fn document(&mut self, retrieval: &str, doc: &Json) -> Result<NodeId, Error> {
        let base = self.intern(retrieval);
        let mut walk = Walk {
            path: String::new(),
            frames: vec![Frame {
                aliases: vec![retrieval.to_string()],
                path_len: 0,
            }],
            base,
        };
        let id = self.schema(doc, &mut walk)?;
        // The root is always registered under its retrieval URI unless some
        // other resource already took it.
        if !self.resources.contains_key(retrieval) {
            self.resources.insert(retrieval.to_string(), id);
        }
        Ok(id)
    }

    fn sub(&mut self, w: &mut Walk, segments: &[&str], json: &Json) -> Result<NodeId, Error> {
        let saved = w.path.len();
        for s in segments {
            w.path.push('/');
            w.path.push_str(&uri::pointer_escape(s));
        }
        let id = self.schema(json, w);
        w.path.truncate(saved);
        id
    }

    fn sub_list(&mut self, w: &mut Walk, name: &str, items: &[Json]) -> Result<Vec<NodeId>, Error> {
        let mut ids = Vec::with_capacity(items.len());
        for (i, item) in items.iter().enumerate() {
            ids.push(self.sub(w, &[name, &i.to_string()], item)?);
        }
        Ok(ids)
    }

    fn sub_map(&mut self, w: &mut Walk, name: &str, map: &Object) -> Result<Vec<(String, NodeId)>, Error> {
        let mut out = Vec::with_capacity(map.len());
        for (k, v) in map.iter() {
            out.push((k.to_string(), self.sub(w, &[name, k], v)?));
        }
        Ok(out)
    }

    fn register_location(&mut self, w: &Walk, id: NodeId) {
        for f in &w.frames {
            let rel = &w.path[f.path_len..];
            for a in &f.aliases {
                self.pointers
                    .entry((a.clone(), rel.to_string()))
                    .or_insert(id);
            }
        }
    }

    fn schema(&mut self, json: &Json, w: &mut Walk) -> Result<NodeId, Error> {
        let id = self.nodes.len();
        let Json::Object(obj) = json else {
            // Booleans are the only other schemas; anything else is treated
            // as the empty schema.
            let constant = json.as_bool().unwrap_or(true);
            self.nodes.push(Node {
                base: w.base,
                constant: Some(constant),
                kw: Keywords::default(),
                needs_annotations: false,
            });
            self.register_location(w, id);
            return Ok(id);
        };

        // $id starts a new resource.
        let saved_base = w.base;
        let mut pushed_frame = false;
        if let Some(Json::String(raw)) = obj.get("$id") {
            let current = self.base_name(w);
            let resolved = uri::resolve(&current, raw);
            let new_base = uri::strip_fragment(&resolved).to_string();
            w.base = self.intern(&new_base);
            self.resources.entry(new_base.clone()).or_insert(id);
            w.frames.push(Frame {
                aliases: vec![new_base],
                path_len: w.path.len(),
            });
            pushed_frame = true;
        }

        self.nodes.push(Node {
            base: w.base,
            constant: None,
            kw: Keywords::default(),
            needs_annotations: false,
        });
        self.register_location(w, id);
        self.register_anchors(obj, w, id);

        let kw = self.keywords(obj, w, id)?;
        let node = &mut self.nodes[id];
        node.needs_annotations = kw.unevaluated_items.is_some() || kw.unevaluated_properties.is_some();
        node.kw = kw;

        if pushed_frame {
            w.frames.pop();
        }
        w.base = saved_base;
        // Keep `base` consistent with the innermost frame.
        Ok(id)
    }

    /// The URI string of the innermost base.
    fn base_name(&self, w: &Walk) -> String {
        w.frames.last().expect("a frame is always present").aliases[0].clone()
    }

    fn register_anchors(&mut self, obj: &Object, w: &Walk, id: NodeId) {
        let innermost = w.frames.last().expect("a frame is always present");
        let aliases: Vec<&String> = w
            .frames
            .iter()
            .rev()
            .take_while(|f| f.path_len == innermost.path_len)
            .flat_map(|f| f.aliases.iter())
            .collect();
        if let Some(Json::String(name)) = obj.get("$dynamicAnchor") {
            for a in &aliases {
                self.dynamic_set.insert(((*a).clone(), name.clone()));
                self.anchors
                    .entry(((*a).clone(), name.clone()))
                    .or_insert(id);
            }
            self.dynamic_by_name
                .entry(name.clone())
                .or_default()
                .entry(w.base)
                .or_insert(id);
        }
        if let Some(Json::String(name)) = obj.get("$anchor") {
            // A plain anchor beats a dynamic anchor of the same name.
            for a in &aliases {
                self.anchors.insert(((*a).clone(), name.clone()), id);
            }
        }
    }

    fn keywords(&mut self, obj: &Object, w: &mut Walk, id: NodeId) -> Result<Keywords, Error> {
        let mut kw = Keywords::default();
        let base = self.base_name(w);
        for (name, value) in obj.iter() {
            match (name, value) {
                ("type", Json::String(t)) => kw.types = kw_u8(t),
                ("type", Json::Array(ts)) => {
                    let mut mask = 0;
                    for t in ts {
                        if let Some(b) = t.as_str().and_then(kw_u8) {
                            mask |= b;
                        }
                    }
                    kw.types = Some(mask);
                }
                ("enum", Json::Array(vs)) => kw.enum_values = Some(vs.clone()),
                ("const", v) => kw.const_value = Some(v.clone()),

                ("multipleOf", Json::Number(n)) => kw.multiple_of = Some(n.clone()),
                ("maximum", Json::Number(n)) => kw.maximum = Some(n.clone()),
                ("minimum", Json::Number(n)) => kw.minimum = Some(n.clone()),
                ("exclusiveMaximum", Json::Number(n)) => kw.exclusive_maximum = Some(n.clone()),
                ("exclusiveMinimum", Json::Number(n)) => kw.exclusive_minimum = Some(n.clone()),

                ("maxLength", Json::Number(n)) => kw.max_length = Some(Limit::new(n)),
                ("minLength", Json::Number(n)) => kw.min_length = Some(Limit::new(n)),
                ("pattern", Json::String(p)) => kw.pattern = Some(self.pattern(p)?),

                ("maxItems", Json::Number(n)) => kw.max_items = Some(Limit::new(n)),
                ("minItems", Json::Number(n)) => kw.min_items = Some(Limit::new(n)),
                ("uniqueItems", Json::Bool(b)) => kw.unique_items = *b,
                ("minContains", Json::Number(n)) => kw.min_contains = Some(Limit::new(n)),
                ("maxContains", Json::Number(n)) => kw.max_contains = Some(Limit::new(n)),
                ("prefixItems", Json::Array(items)) => {
                    kw.prefix_items = Some(self.sub_list(w, "prefixItems", items)?);
                }
                ("items", v) => kw.items = Some(self.sub(w, &["items"], v)?),
                ("contains", v) => kw.contains = Some(self.sub(w, &["contains"], v)?),

                ("maxProperties", Json::Number(n)) => kw.max_properties = Some(Limit::new(n)),
                ("minProperties", Json::Number(n)) => kw.min_properties = Some(Limit::new(n)),
                ("required", Json::Array(names)) => {
                    kw.required = names.iter().filter_map(|n| n.as_str().map(String::from)).collect();
                }
                ("dependentRequired", Json::Object(map)) => {
                    for (k, v) in map.iter() {
                        if let Json::Array(names) = v {
                            let names = names.iter().filter_map(|n| n.as_str().map(String::from)).collect();
                            kw.dependent_required.push((k.to_string(), names));
                        }
                    }
                }
                ("properties", Json::Object(map)) => {
                    kw.properties = self.sub_map(w, "properties", map)?;
                    kw.property_index = kw
                        .properties
                        .iter()
                        .enumerate()
                        .map(|(i, (k, _))| (k.clone(), i))
                        .collect();
                }
                ("patternProperties", Json::Object(map)) => {
                    for (k, v) in map.iter() {
                        let re = self.pattern(k)?;
                        let sub = self.sub(w, &["patternProperties", k], v)?;
                        kw.pattern_properties.push((re, sub));
                    }
                }
                ("additionalProperties", v) => {
                    kw.additional_properties = Some(self.sub(w, &["additionalProperties"], v)?);
                }
                ("propertyNames", v) => kw.property_names = Some(self.sub(w, &["propertyNames"], v)?),
                ("dependentSchemas", Json::Object(map)) => {
                    kw.dependent_schemas = self.sub_map(w, "dependentSchemas", map)?;
                }

                ("allOf", Json::Array(items)) => kw.all_of = Some(self.sub_list(w, "allOf", items)?),
                ("anyOf", Json::Array(items)) => kw.any_of = Some(self.sub_list(w, "anyOf", items)?),
                ("oneOf", Json::Array(items)) => kw.one_of = Some(self.sub_list(w, "oneOf", items)?),
                ("not", v) => kw.not = Some(self.sub(w, &["not"], v)?),
                ("if", v) => kw.if_ = Some(self.sub(w, &["if"], v)?),
                ("then", v) => kw.then_ = Some(self.sub(w, &["then"], v)?),
                ("else", v) => kw.else_ = Some(self.sub(w, &["else"], v)?),
                ("unevaluatedItems", v) => {
                    kw.unevaluated_items = Some(self.sub(w, &["unevaluatedItems"], v)?);
                }
                ("unevaluatedProperties", v) => {
                    kw.unevaluated_properties = Some(self.sub(w, &["unevaluatedProperties"], v)?);
                }

                // Indexed (for $ref targets) but never applied.
                ("$defs", Json::Object(map)) => {
                    self.sub_map(w, "$defs", map)?;
                }
                ("contentSchema", v) => {
                    self.sub(w, &["contentSchema"], v)?;
                }

                ("$ref", Json::String(r)) => {
                    self.pending.push(Pending::Ref(id, uri::resolve(&base, r)));
                }
                ("$dynamicRef", Json::String(r)) => {
                    self.pending.push(Pending::Dynamic(id, uri::resolve(&base, r)));
                }
                _ => {}
            }
        }
        Ok(kw)
    }

    /// Looks up the target of an absolute reference.
    fn lookup(&self, absolute: &str) -> Option<NodeId> {
        let (doc, fragment) = uri::split_fragment(absolute);
        let fragment = uri::percent_decode(fragment.unwrap_or(""));
        if fragment.is_empty() {
            self.resources.get(doc).copied()
        } else if fragment.starts_with('/') {
            self.pointers.get(&(doc.to_string(), fragment)).copied()
        } else {
            self.anchors.get(&(doc.to_string(), fragment)).copied()
        }
    }

    fn finish(mut self, root: NodeId) -> Schema {
        let pending = std::mem::take(&mut self.pending);
        let mut table_index: HashMap<String, usize> = HashMap::new();
        let mut tables: Vec<HashMap<u32, NodeId>> = Vec::new();
        for p in pending {
            match p {
                Pending::Ref(node, abs) => {
                    let target = self.lookup(&abs);
                    self.nodes[node].kw.reference = Some(target);
                }
                Pending::Dynamic(node, abs) => {
                    let target = self.lookup(&abs);
                    let (doc, fragment) = uri::split_fragment(&abs);
                    let name = uri::percent_decode(fragment.unwrap_or(""));
                    let dynamic = !name.is_empty()
                        && !name.starts_with('/')
                        && self.dynamic_set.contains(&(doc.to_string(), name.clone()));
                    let table = if dynamic {
                        let idx = *table_index.entry(name.clone()).or_insert_with(|| {
                            tables.push(self.dynamic_by_name.get(&name).cloned().unwrap_or_default());
                            tables.len() - 1
                        });
                        Some(idx)
                    } else {
                        None
                    };
                    self.nodes[node].kw.dynamic_reference = Some(DynamicRef { target, table });
                }
            }
        }
        Schema {
            nodes: self.nodes,
            root,
            dynamic_tables: tables,
        }
    }
}
