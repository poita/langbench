// Package softfloat implements IEEE-754 binary32 (single precision)
// arithmetic in software, using only integer operations.
//
// Values are exchanged as raw 32-bit patterns (uint32). Addition,
// subtraction, multiplication, division and square root are provided, all
// with round-to-nearest-even and full gradual underflow (denormals). Any NaN
// input, and every invalid operation, yields the canonical quiet NaN
// (QNaN, 0x7fc00000). Exception flags are not modelled.
//
// The implementation never uses host floating point. Each operation computes
// a truncated integer result plus a sticky bit that fits in 64 bits, and a
// single shared step (roundPack) rounds it onto the binary32 grid.
package softfloat
