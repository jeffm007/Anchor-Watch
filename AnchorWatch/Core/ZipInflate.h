#ifndef ANCHORWATCH_ZIP_INFLATE_H
#define ANCHORWATCH_ZIP_INFLATE_H
#include <stdint.h>
#include <stddef.h>

/// Inflates one raw DEFLATE ZIP entry. Returns 0 on success.
int aw_inflate_raw(const uint8_t *input, uint32_t input_length,
                   uint8_t *output, uint32_t output_length);
uint32_t aw_crc32(const uint8_t *bytes, uint32_t length);
#endif
