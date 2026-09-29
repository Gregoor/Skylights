#include "Gzip.h"
#include <stdio.h>
#include <string.h>
#include <zlib.h>

int tmdb_gzip_file(const char *source, const char *destination, char *error, size_t error_capacity) {
    FILE *in = fopen(source, "rb");
    if (!in) { snprintf(error, error_capacity, "cannot open gzip input"); return -1; }
    FILE *out = fopen(destination, "wb");
    if (!out) { fclose(in); snprintf(error, error_capacity, "cannot open output file"); return -1; }
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    int code = inflateInit2(&stream, 15 + 16);
    if (code != Z_OK) { fclose(in); fclose(out); snprintf(error, error_capacity, "inflateInit2 failed: %d", code); return code; }
    unsigned char input[128 * 1024], output[128 * 1024];
    int result = Z_OK;
    while (result == Z_OK) {
        stream.avail_in = (uInt)fread(input, 1, sizeof(input), in);
        if (ferror(in)) { result = Z_ERRNO; break; }
        if (stream.avail_in == 0) { result = Z_DATA_ERROR; break; }
        stream.next_in = input;
        do {
            stream.avail_out = (uInt)sizeof(output);
            stream.next_out = output;
            result = inflate(&stream, Z_NO_FLUSH);
            if (result != Z_OK && result != Z_STREAM_END) break;
            size_t produced = sizeof(output) - stream.avail_out;
            if (produced && fwrite(output, 1, produced, out) != produced) { result = Z_ERRNO; break; }
        } while (stream.avail_out == 0);
    }
    inflateEnd(&stream);
    fclose(in);
    if (fclose(out) != 0 && result == Z_STREAM_END) result = Z_ERRNO;
    if (result != Z_STREAM_END) {
        remove(destination);
        snprintf(error, error_capacity, "gzip inflate failed: %d", result);
        return result;
    }
    return 0;
}
