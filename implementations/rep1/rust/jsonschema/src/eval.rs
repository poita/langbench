//! The validator: evaluates a compiled [`Schema`] against instances.
//!
//! Evaluation returns accept/reject and, when an `unevaluatedItems` or
//! `unevaluatedProperties` keyword needs them, the set of evaluated array
//! indices / object member positions (SPEC §4). A schema object only adds to
//! its caller's set when it accepts, so annotations never escape a rejected
//! branch.

use crate::json::{Json, Object};
use crate::schema::{
    Keywords, NodeId, Schema, T_ARRAY, T_BOOLEAN, T_INTEGER, T_NULL, T_NUMBER, T_OBJECT, T_STRING,
};
use std::collections::HashSet;

/// A set of evaluated array indices or object member positions, as a bitset
/// sized for the instance it describes.
struct Ann {
    bits: Vec<u64>,
}

impl Ann {
    fn new(n: usize) -> Ann {
        Ann {
            bits: vec![0; n.div_ceil(64)],
        }
    }

    fn set(&mut self, i: usize) {
        self.bits[i / 64] |= 1 << (i % 64);
    }

    fn get(&self, i: usize) -> bool {
        self.bits[i / 64] >> (i % 64) & 1 == 1
    }

    fn merge(&mut self, other: &Ann) {
        for (a, b) in self.bits.iter_mut().zip(&other.bits) {
            *a |= *b;
        }
    }
}

/// Mutable annotation slot threaded through in-place applicators.
type Slot<'a> = Option<&'a mut Ann>;

impl Schema {
    /// Returns `true` if `instance` satisfies the schema.
    pub fn is_valid(&self, instance: &Json) -> bool {
        let mut ev = Evaluator {
            schema: self,
            scope: Vec::new(),
        };
        ev.eval(self.root, instance, None)
    }
}

struct Evaluator<'s> {
    schema: &'s Schema,
    /// The dynamic scope: base URI ids, outermost first.
    scope: Vec<u32>,
}

fn instance_size(inst: &Json) -> usize {
    match inst {
        Json::Array(a) => a.len(),
        Json::Object(o) => o.len(),
        _ => 0,
    }
}

fn type_mask(inst: &Json) -> u8 {
    match inst {
        Json::Null => T_NULL,
        Json::Bool(_) => T_BOOLEAN,
        Json::Object(_) => T_OBJECT,
        Json::Array(_) => T_ARRAY,
        Json::String(_) => T_STRING,
        Json::Number(n) => {
            if n.is_integer() {
                T_NUMBER | T_INTEGER
            } else {
                T_NUMBER
            }
        }
    }
}

fn all_unique(items: &[Json]) -> bool {
    if items.len() < 2 {
        return true;
    }
    if items.len() <= 8 {
        return items
            .iter()
            .enumerate()
            .all(|(i, a)| items[i + 1..].iter().all(|b| a != b));
    }
    let mut seen: HashSet<&Json> = HashSet::with_capacity(items.len());
    items.iter().all(|v| seen.insert(v))
}

impl<'s> Evaluator<'s> {
    /// Evaluates schema node `id` against `inst`. On acceptance the node's
    /// evaluated items/properties are merged into `out`; on rejection `out`
    /// is untouched.
    fn eval(&mut self, id: NodeId, inst: &Json, out: Slot<'_>) -> bool {
        let schema = self.schema;
        let node = &schema.nodes[id];
        if let Some(b) = node.constant {
            return b;
        }
        let pushed = self.scope.last() != Some(&node.base);
        if pushed {
            self.scope.push(node.base);
        }
        let ok = self.eval_object(&node.kw, node.needs_annotations, inst, out);
        if pushed {
            self.scope.pop();
        }
        ok
    }

    fn eval_object(&mut self, kw: &Keywords, needs_ann: bool, inst: &Json, out: Slot<'_>) -> bool {
        let mut local = if out.is_some() || needs_ann {
            Some(Ann::new(instance_size(inst)))
        } else {
            None
        };

        if let Some(mask) = kw.types {
            if mask & type_mask(inst) == 0 {
                return false;
            }
        }
        if let Some(values) = &kw.enum_values {
            if !values.iter().any(|v| v == inst) {
                return false;
            }
        }
        if let Some(v) = &kw.const_value {
            if v != inst {
                return false;
            }
        }

        match inst {
            Json::Number(n) => {
                if kw.multiple_of.as_ref().is_some_and(|m| !n.is_multiple_of(m))
                    || kw.maximum.as_ref().is_some_and(|m| n > m)
                    || kw.minimum.as_ref().is_some_and(|m| n < m)
                    || kw.exclusive_maximum.as_ref().is_some_and(|m| n >= m)
                    || kw.exclusive_minimum.as_ref().is_some_and(|m| n <= m)
                {
                    return false;
                }
            }
            Json::String(s) => {
                if kw.max_length.is_some() || kw.min_length.is_some() {
                    let len = s.chars().count();
                    if kw.max_length.as_ref().is_some_and(|l| !l.allows_at_most(len))
                        || kw.min_length.as_ref().is_some_and(|l| !l.allows_at_least(len))
                    {
                        return false;
                    }
                }
                if kw.pattern.as_ref().is_some_and(|re| !re.is_match(s)) {
                    return false;
                }
            }
            Json::Array(items) => {
                if !self.eval_array(kw, items, &mut local) {
                    return false;
                }
            }
            Json::Object(obj) => {
                if !self.eval_properties(kw, obj, &mut local) {
                    return false;
                }
            }
            _ => {}
        }

        if !self.eval_in_place(kw, inst, &mut local) {
            return false;
        }

        // unevaluated*: applied last, against everything collected above.
        match inst {
            Json::Array(items) => {
                if let (Some(u), Some(l)) = (kw.unevaluated_items, local.as_mut()) {
                    for (i, item) in items.iter().enumerate() {
                        if !l.get(i) {
                            if !self.eval(u, item, None) {
                                return false;
                            }
                            l.set(i);
                        }
                    }
                }
            }
            Json::Object(obj) => {
                if let (Some(u), Some(l)) = (kw.unevaluated_properties, local.as_mut()) {
                    for i in 0..obj.len() {
                        if !l.get(i) {
                            if !self.eval(u, obj.entry(i).1, None) {
                                return false;
                            }
                            l.set(i);
                        }
                    }
                }
            }
            _ => {}
        }

        if let (Some(out), Some(local)) = (out, local) {
            out.merge(&local);
        }
        true
    }

    fn eval_array(&mut self, kw: &Keywords, items: &[Json], local: &mut Option<Ann>) -> bool {
        let len = items.len();
        if kw.max_items.as_ref().is_some_and(|l| !l.allows_at_most(len))
            || kw.min_items.as_ref().is_some_and(|l| !l.allows_at_least(len))
        {
            return false;
        }
        if kw.unique_items && !all_unique(items) {
            return false;
        }
        let mut start = 0;
        if let Some(prefix) = &kw.prefix_items {
            start = prefix.len();
            for (i, (&sub, item)) in prefix.iter().zip(items).enumerate() {
                if !self.eval(sub, item, None) {
                    return false;
                }
                if let Some(l) = local.as_mut() {
                    l.set(i);
                }
            }
        }
        if let Some(sub) = kw.items {
            for (i, item) in items.iter().enumerate().skip(start) {
                if !self.eval(sub, item, None) {
                    return false;
                }
                if let Some(l) = local.as_mut() {
                    l.set(i);
                }
            }
        }
        if let Some(sub) = kw.contains {
            let min_ok = |n: usize| kw.min_contains.as_ref().map_or(n >= 1, |l| l.allows_at_least(n));
            let exhaustive = local.is_some() || kw.max_contains.is_some();
            let mut count = 0usize;
            for (i, item) in items.iter().enumerate() {
                if self.eval(sub, item, None) {
                    count += 1;
                    if let Some(l) = local.as_mut() {
                        l.set(i);
                    }
                    if !exhaustive && min_ok(count) {
                        break;
                    }
                }
            }
            if !min_ok(count) || kw.max_contains.as_ref().is_some_and(|l| !l.allows_at_most(count)) {
                return false;
            }
        }
        true
    }

    fn eval_properties(&mut self, kw: &Keywords, obj: &Object, local: &mut Option<Ann>) -> bool {
        let len = obj.len();
        if kw.max_properties.as_ref().is_some_and(|l| !l.allows_at_most(len))
            || kw.min_properties.as_ref().is_some_and(|l| !l.allows_at_least(len))
        {
            return false;
        }
        if kw.required.iter().any(|name| !obj.contains_key(name)) {
            return false;
        }
        for (name, needed) in &kw.dependent_required {
            if obj.contains_key(name) && needed.iter().any(|n| !obj.contains_key(n)) {
                return false;
            }
        }

        let has_patterns = !kw.pattern_properties.is_empty();
        if kw.additional_properties.is_none() && !has_patterns {
            // Only `properties`: iterate whichever side is smaller.
            if kw.properties.len() <= len {
                for (name, sub) in &kw.properties {
                    if let Some(i) = obj.position(name) {
                        if !self.eval(*sub, obj.entry(i).1, None) {
                            return false;
                        }
                        if let Some(l) = local.as_mut() {
                            l.set(i);
                        }
                    }
                }
            } else {
                for i in 0..len {
                    let (name, value) = obj.entry(i);
                    if let Some(&p) = kw.property_index.get(name) {
                        if !self.eval(kw.properties[p].1, value, None) {
                            return false;
                        }
                        if let Some(l) = local.as_mut() {
                            l.set(i);
                        }
                    }
                }
            }
        } else {
            for i in 0..len {
                let (name, value) = obj.entry(i);
                let mut matched = false;
                if let Some(&p) = kw.property_index.get(name) {
                    matched = true;
                    if !self.eval(kw.properties[p].1, value, None) {
                        return false;
                    }
                }
                for (re, sub) in &kw.pattern_properties {
                    if re.is_match(name) {
                        matched = true;
                        if !self.eval(*sub, value, None) {
                            return false;
                        }
                    }
                }
                if !matched {
                    if let Some(sub) = kw.additional_properties {
                        matched = true;
                        if !self.eval(sub, value, None) {
                            return false;
                        }
                    }
                }
                if matched {
                    if let Some(l) = local.as_mut() {
                        l.set(i);
                    }
                }
            }
        }

        if let Some(sub) = kw.property_names {
            for (name, _) in obj.iter() {
                if !self.eval(sub, &Json::String(name.to_string()), None) {
                    return false;
                }
            }
        }
        true
    }

    fn eval_in_place(&mut self, kw: &Keywords, inst: &Json, local: &mut Option<Ann>) -> bool {
        if let Json::Object(obj) = inst {
            for (name, sub) in &kw.dependent_schemas {
                if obj.contains_key(name) && !self.eval(*sub, inst, local.as_mut()) {
                    return false;
                }
            }
        }
        if let Some(target) = kw.reference {
            match target {
                Some(t) => {
                    if !self.eval(t, inst, local.as_mut()) {
                        return false;
                    }
                }
                None => return false,
            }
        }
        if let Some(dynamic) = &kw.dynamic_reference {
            let mut target = dynamic.target;
            if let Some(table) = dynamic.table {
                let table = &self.schema.dynamic_tables[table];
                if let Some(t) = self.scope.iter().find_map(|b| table.get(b)) {
                    target = Some(*t);
                }
            }
            match target {
                Some(t) => {
                    if !self.eval(t, inst, local.as_mut()) {
                        return false;
                    }
                }
                None => return false,
            }
        }
        if let Some(subs) = &kw.all_of {
            for &s in subs {
                if !self.eval(s, inst, local.as_mut()) {
                    return false;
                }
            }
        }
        if let Some(subs) = &kw.any_of {
            let mut any = false;
            for &s in subs {
                if self.eval(s, inst, local.as_mut()) {
                    any = true;
                    if local.is_none() {
                        break;
                    }
                }
            }
            if !any {
                return false;
            }
        }
        if let Some(subs) = &kw.one_of {
            let mut count = 0;
            for &s in subs {
                if self.eval(s, inst, local.as_mut()) {
                    count += 1;
                    if count > 1 {
                        return false;
                    }
                }
            }
            if count != 1 {
                return false;
            }
        }
        if let Some(s) = kw.not {
            if self.eval(s, inst, None) {
                return false;
            }
        }
        if let Some(cond) = kw.if_ {
            if self.eval(cond, inst, local.as_mut()) {
                if let Some(t) = kw.then_ {
                    if !self.eval(t, inst, local.as_mut()) {
                        return false;
                    }
                }
            } else if let Some(e) = kw.else_ {
                if !self.eval(e, inst, local.as_mut()) {
                    return false;
                }
            }
        }
        true
    }
}
