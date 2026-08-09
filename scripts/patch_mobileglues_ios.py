#!/usr/bin/env python3
"""Apply minimal Darwin/iOS build fixes to pinned MobileGlues 2.0.0.

The goal is to preserve upstream renderer behavior while replacing constructs
that are valid on ELF/Linux but are rejected by Apple's Mach-O toolchain.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MG = ROOT / "Natives" / "external" / "MobileGlues" / "MobileGlues-cpp"
FB = MG / "gl" / "framebuffer.cpp"
TRACE = MG / "egl" / "trace.h"


def patch_exact(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text(encoding="utf-8")
    if old in text:
        path.write_text(text.replace(old, new, 1), encoding="utf-8")
        print(f"Patched {label}")
        return
    if new in text:
        print(f"{label} already applied")
        return
    raise SystemExit(f"patch_mobileglues_ios: expected block not found for {label}")


# Darwin/Mach-O does not support GCC's ELF alias attribute. Export forwarding
# wrappers with identical public names instead.
patch_exact(
    FB,
    '''extern "C" {
GLAPI GLAPIENTRY void glDeleteFramebuffersARB(GLsizei n, const GLuint* names) __attribute__((alias("glDeleteFramebuffers")));
GLAPI GLAPIENTRY void glFramebufferRenderbufferARB(GLenum target, GLenum attachment, GLenum renderbuffertarget,
                                                   GLuint renderbuffer) __attribute__((alias("glFramebufferRenderbuffer")));
GLAPI GLAPIENTRY void glFramebufferTextureLayerARB(GLenum target, GLenum attachment, GLuint texture, GLint level,
                                                   GLint layer) __attribute__((alias("glFramebufferTextureLayer")));
}
''',
    '''extern "C" {
// Darwin/Mach-O does not support GCC's ELF alias attribute. Forwarding wrappers
// preserve the exported ARB spellings without changing renderer semantics.
GLAPI GLAPIENTRY void glDeleteFramebuffersARB(GLsizei n, const GLuint* names) {
    glDeleteFramebuffers(n, names);
}
GLAPI GLAPIENTRY void glFramebufferRenderbufferARB(GLenum target, GLenum attachment, GLenum renderbuffertarget,
                                                   GLuint renderbuffer) {
    glFramebufferRenderbuffer(target, attachment, renderbuffertarget, renderbuffer);
}
GLAPI GLAPIENTRY void glFramebufferTextureLayerARB(GLenum target, GLenum attachment, GLuint texture, GLint level,
                                                   GLint layer) {
    glFramebufferTextureLayer(target, attachment, texture, level, layer);
}
}
''',
    "MobileGlues framebuffer ARB exports for Darwin/Mach-O",
)

# __NR_gettid is a Linux syscall constant. Use Apple's supported pthread thread
# id API on Darwin. EGL tracing is compiled out by default, but the inline helper
# still has to compile.
patch_exact(
    TRACE,
    '''#include <sys/syscall.h>
#include <unistd.h>
''',
    '''#if defined(__APPLE__)
#include <pthread.h>
#include <stdint.h>
#else
#include <sys/syscall.h>
#include <unistd.h>
#endif
''',
    "MobileGlues platform thread-id includes",
)

patch_exact(
    TRACE,
    '''static inline int mg_egl_tid(void) {
    return (int)syscall(__NR_gettid);
}
''',
    '''static inline int mg_egl_tid(void) {
#if defined(__APPLE__)
    uint64_t tid = 0;
    pthread_threadid_np(NULL, &tid);
    return (int)tid;
#else
    return (int)syscall(__NR_gettid);
#endif
}
''',
    "MobileGlues EGL thread-id implementation for Darwin",
)
