// Package protowire is a small Protocol Buffers (proto3) wire-format codec
// driven by a runtime schema rather than generated code.
//
// A schema is written in a tiny subset of the .proto language and parsed with
// [ParseSchema]. Given a message type from the schema, a [MessageDesc], you
// can
//
//   - decode wire bytes into a [Message] tree with [MessageDesc.Unmarshal],
//   - parse the canonical text form (for example {a: 1, c: [1, 2]}) with
//     [MessageDesc.ParseText],
//   - print a message as canonical text with [Message.String] or
//     [Message.AppendText], and
//   - encode a message to canonical wire bytes with [Message.Marshal].
//
// Decoding follows proto3 rules: unknown fields and fields of the wrong wire
// type are skipped, groups are skipped, repeated numeric fields accept packed
// and unpacked forms, and repeated occurrences of a singular message field are
// merged. Encoding is canonical and deterministic. All operations are linear
// in the size of their input plus output.
//
// Source files by responsibility: schema.go (schema parsing), wire.go (varints,
// tags, skipping), decode.go, encode.go, text.go (text form printing and
// parsing) and message.go (the value tree).
package protowire
