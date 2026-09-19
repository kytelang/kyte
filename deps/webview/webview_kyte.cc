// The Kyte-glue half of the native `webview` backing: the two adapter shims the binding
// in src/lib/std/webview.ky needs, which turn a Kyte closure into the C callback shapes
// webview expects. WEBVIEW_HEADER keeps this translation unit declarations-only (the
// implementation lives in webview_impl.cc), so the two objects archive together without
// duplicate symbols. The plain C API (create/navigate/run/...) is called directly from
// webview.ky and needs no adapter.

#define WEBVIEW_HEADER
#include "webview.h"

#include <cstring>
#include <cstdlib>

// Runtime helpers exported by libkytecore: invoke a Kyte closure from its box pointer
// (box[0] = code, box[1] = env), and allocate a Kyte string buffer (4-byte length prefix
// at p-4).
extern "C" {
long long kyte_invoke_str_closure(long long box, long long arg);
void kyte_invoke_void_closure(long long box);
char *kyte_bytes_alloc(long long n);
}

// Build a Kyte string (NUL-terminated, length prefix at p-4) from a C string, so a bound
// handler receives the request JSON as a real Kyte `string`.
static const char *kyte_str_from_c(const char *c) {
  long long len = c ? (long long)std::strlen(c) : 0;
  char *p = kyte_bytes_alloc(len + 1);
  if (!p) return nullptr;
  if (c && len) std::memcpy(p, c, (size_t)len);
  p[len] = '\0';
  *reinterpret_cast<int *>(p - 4) = (int)len;
  return p;
}

// Per-binding trampoline state: the Kyte closure box and the owning webview handle.
struct KyteBind {
  long long box;
  webview_t w;
};

static void kyte_bind_thunk(const char *seq, const char *req, void *arg) {
  KyteBind *b = reinterpret_cast<KyteBind *>(arg);
  const char *kreq = kyte_str_from_c(req ? req : "");
  long long kres = kyte_invoke_str_closure(b->box, reinterpret_cast<long long>(kreq));
  const char *cres = reinterpret_cast<const char *>(kres); // Kyte strings are NUL-terminated
  webview_return(b->w, seq, 0, cres ? cres : "");
}

// Bind a Kyte `(string) -> string` closure under `name`; page-side `window.<name>(arg)`
// then round-trips through the closure.
extern "C" void kyte_webview_bind(void *w, const char *name, long long handler) {
  KyteBind *b = new KyteBind{handler, reinterpret_cast<webview_t>(w)};
  webview_bind(reinterpret_cast<webview_t>(w), name, kyte_bind_thunk, b);
}

static void kyte_dispatch_thunk(webview_t /*w*/, void *arg) {
  kyte_invoke_void_closure(reinterpret_cast<long long>(arg));
}

// Run a Kyte `() -> void` closure on the webview's UI thread.
extern "C" void kyte_webview_dispatch(void *w, long long task) {
  webview_dispatch(reinterpret_cast<webview_t>(w), kyte_dispatch_thunk,
                   reinterpret_cast<void *>(task));
}
