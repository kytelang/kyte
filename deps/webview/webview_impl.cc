// The implementation half of Kyte's native `webview` backing. Including webview.h here
// WITHOUT defining WEBVIEW_HEADER pulls in the full implementation of the vendored MIT
// webview library in this single translation unit (WKWebView-backed on macOS). The
// install step compiles this as Objective-C++ (`clang++ -ObjC++`) and archives it into
// libwebview.a; the WebKit and Cocoa frameworks are linked into the final program by
// appendFfiLib, not here.
#include "webview.h"
