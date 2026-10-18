
#ifndef KYTE_RUNTIME_STR_H
#define KYTE_RUNTIME_STR_H
#include "kyte_abi.h"
#include <cstdlib>
#include <cstring>
#include <cstdio>

static inline char *kyte_to_cstr(const char *s) {
  if (!s)
    return nullptr;
  int len = *reinterpret_cast<const int *>(s - 4);
  // Always copy EXACTLY the logical length into a freshly NUL-terminated buffer.
  // The previous code returned the uncopied Kyte pointer for `len > 1 MiB` (and for
  // a negative/corrupt header), relying on a trailing NUL that not every string
  // allocation path guarantees -- a C consumer reading it as a NUL-terminated string
  // could then walk past the logical length (over-read / info-leak). Copying is bounded
  // by `len`, so it is safe regardless of the source's termination; a corrupt negative
  // header is clamped to empty rather than trusted.
  if (len < 0)
    len = 0;
  char *out = (char *)std::malloc((size_t)len + 1);
  if (out) {
    std::memcpy(out, s, (size_t)len);
    out[len] = '\0';
  }
  return out;
}
static inline void kyte_free_cstr(const char *kyte_str, char *c) {
  if (c && c != kyte_str)
    std::free(c);
}

static inline const char *kyte_from_bytes(const char *src, long long len) {
  if (len < 0)
    len = 0;
  // Fail closed above the i32 length-prefix limit instead of silently truncating it.
  // The ARC header stores the logical length as a 32-bit int; a string at or above 2 GiB
  // would wrap to a garbage (often negative or tiny) length, which downstream becomes a
  // corrupt Content-Length and a hung response (the `html as string` class of bug). A
  // multi-gigabyte single string is never legitimate here, so abort with a diagnostic
  // rather than hand back a value with a lying length.
  if (len > 0x7fffffffLL) {
    fputs("fatal: kyte_from_bytes: string length exceeds the 2 GiB limit; refusing to truncate the length header\n", stderr);
    abort();
  }
  // Allocate one extra byte for a NUL terminator so the debugger's built-in char* view (and C-FFI) can
  // read the string without Python formatters. The ARC header length stays the LOGICAL length -- we
  // over-allocate by one, then rewrite the length field, which kyte_bytes_alloc set to len+1.
  char *p = (char *)kyte_bytes_alloc(len + 1);
  if (!p)
    return nullptr;
  if (src && len > 0)
    std::memcpy(p, src, (size_t)len);
  p[len] = '\0';
  *reinterpret_cast<int *>(p - 4) = (int)len;
  return p;
}

static inline const char *kyte_from_cstr(const char *c) {
  if (!c)
    return nullptr;
  return kyte_from_bytes(c, (long long)std::strlen(c));
}
#endif
