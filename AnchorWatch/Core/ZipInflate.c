#include "ZipInflate.h"
#include <zlib.h>
#include <string.h>

int aw_inflate_raw(const uint8_t *input, uint32_t input_length,
                   uint8_t *output, uint32_t output_length) {
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    stream.next_in = (Bytef *)input;
    stream.avail_in = (uInt)input_length;
    stream.next_out = output;
    stream.avail_out = (uInt)output_length;
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return Z_STREAM_ERROR;
    int result = inflate(&stream, Z_FINISH);
    int finish = inflateEnd(&stream);
    if (result != Z_STREAM_END || finish != Z_OK || stream.total_out != output_length) return Z_DATA_ERROR;
    return Z_OK;
}

uint32_t aw_crc32(const uint8_t *bytes, uint32_t length) {
    return (uint32_t)crc32(0L, bytes, (uInt)length);
}
