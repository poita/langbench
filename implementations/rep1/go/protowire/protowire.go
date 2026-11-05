// Package protowire is a small Protocol Buffers wire-format codec driven by
// a text schema, with a canonical text form for messages.
//
// Parse a schema, then convert between wire bytes and text:
//
//	sch, _ := protowire.ParseSchema("message P { int32 id = 1; string name = 2; }")
//	c := protowire.NewCodec(sch)
//	wireBytes, _ := c.Encode("P", `{id: 7, name: "ann"}`)
//	text, _ := c.Decode("P", wireBytes) // {id: 7, name: "ann"}
//
// The implementation lives in subpackages: wire (varint and hex
// primitives), schema (schema language and compiled types), codec (decode
// and encode) and batch (the line-oriented request protocol used by the
// command-line tool).
package protowire

import (
	"protowire/batch"
	"protowire/codec"
	"protowire/schema"
)

// Schema is a compiled set of message types.
type Schema = schema.Schema

// Codec encodes and decodes messages of one schema. It is not safe for
// concurrent use.
type Codec = codec.Codec

// ParseSchema compiles schema source text.
func ParseSchema(src string) (*Schema, error) { return schema.Parse([]byte(src)) }

// NewCodec returns a Codec for s.
func NewCodec(s *Schema) *Codec { return codec.New(s) }

// Process answers a complete request document (schema, "--" line, requests)
// and returns the output lines. See package batch for the format.
func Process(input []byte) ([]byte, error) { return batch.Run(input) }
