// RUN: %clang_cc1 -fsyntax-only -verify=neon -triple aarch64-arm-none-eabi \
// RUN: -target-feature -fp8 -target-feature +neon %s

// REQUIRES: aarch64-registered-target

#include <arm_neon.h>

void test_vector(mfloat8x8_t a, mfloat8x16_t b, uint8x8_t c) {
  a + b;  // neon-error {{invalid operands to binary expression ('mfloat8x8_t' (aka '__MFloat8x8_t') and 'mfloat8x16_t' (aka '__MFloat8x16_t'))}}
  a - b;  // neon-error {{invalid operands to binary expression ('mfloat8x8_t' (aka '__MFloat8x8_t') and 'mfloat8x16_t' (aka '__MFloat8x16_t'))}}
  a * b;  // neon-error {{invalid operands to binary expression ('mfloat8x8_t' (aka '__MFloat8x8_t') and 'mfloat8x16_t' (aka '__MFloat8x16_t'))}}
  a / b;  // neon-error {{invalid operands to binary expression ('mfloat8x8_t' (aka '__MFloat8x8_t') and 'mfloat8x16_t' (aka '__MFloat8x16_t'))}}

  a + c;  // neon-error {{cannot convert between vector and non-scalar values ('mfloat8x8_t' (aka '__MFloat8x8_t') and 'uint8x8_t' (vector of 8 'uint8_t' values))}}
  a - c;  // neon-error {{cannot convert between vector and non-scalar values ('mfloat8x8_t' (aka '__MFloat8x8_t') and 'uint8x8_t' (vector of 8 'uint8_t' values))}}
  a * c;  // neon-error {{cannot convert between vector and non-scalar values ('mfloat8x8_t' (aka '__MFloat8x8_t') and 'uint8x8_t' (vector of 8 'uint8_t' values))}}
  a / c;  // neon-error {{cannot convert between vector and non-scalar values ('mfloat8x8_t' (aka '__MFloat8x8_t') and 'uint8x8_t' (vector of 8 'uint8_t' values))}}
  c + b;  // neon-error {{cannot convert between vector and non-scalar values ('uint8x8_t' (vector of 8 'uint8_t' values) and 'mfloat8x16_t' (aka '__MFloat8x16_t'))}}
  c - b;  // neon-error {{cannot convert between vector and non-scalar values ('uint8x8_t' (vector of 8 'uint8_t' values) and 'mfloat8x16_t' (aka '__MFloat8x16_t'))}}
  c * b;  // neon-error {{cannot convert between vector and non-scalar values ('uint8x8_t' (vector of 8 'uint8_t' values) and 'mfloat8x16_t' (aka '__MFloat8x16_t'))}}
  c / b;  // neon-error {{cannot convert between vector and non-scalar values ('uint8x8_t' (vector of 8 'uint8_t' values) and 'mfloat8x16_t' (aka '__MFloat8x16_t'))}}
}
