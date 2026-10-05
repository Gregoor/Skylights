#ifndef TMDBGZIP_H
#define TMDBGZIP_H
#include <stddef.h>
int tmdb_gzip_file(const char *source, const char *destination, char *error, size_t error_capacity);
#endif
