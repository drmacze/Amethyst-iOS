#!/usr/bin/env python3
"""Apply Darwin/iOS compatibility and performance fixes to MobileGlues 2.0.0.

The compatibility changes preserve upstream renderer behaviour where ELF/Linux
constructs are rejected by Apple's Mach-O toolchain. The v3 build also corrects
a MobileGlues CMake branch that leaves AppleClang on -O2 even for a Release
build; the A13 artifact deliberately uses -O3 while keeping ThinLTO enabled.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MG = ROOT / "Natives" / "external" / "MobileGlues" / "MobileGlues-cpp"
FB = MG / "gl" / "framebuffer.cpp"
TRACE = MG / "egl" / "trace.h"
CMAKE = MG / "CMakeLists.txt"


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

# -Bsymbolic-functions is a GNU/ELF linker option and Apple's ld rejects it.
# Keep it on Linux/Android, but do not pass it to Mach-O.
patch_exact(
    CMAKE,
    '''if (NOT MSVC)
    # Calls between this library's own translation units must land in this
    # library. Without this, an internal call to an exported gl* symbol goes
    # through a preemptible PLT slot, and in an Android app process the system
    # libGLESv2 -- always in the global symbol scope -- can win the lookup: the
    # DSA wrappers and the benchmark would then be calling the real driver where
    # they meant the frontend, silently bypassing all state tracking. The
    # symbols stay exported for dlsym and eglGetProcAddress; only who internal
    # calls bind to changes. On the target, not in the AppleClang-guarded block
    # above -- that block's condition has never been true (dangling NOT MATCHES),
    # which is also why --gc-sections never made it into the link.
    target_link_options(${CMAKE_PROJECT_NAME} PRIVATE -Wl,-Bsymbolic-functions)
endif()
''',
    '''if (NOT MSVC AND NOT MACOS)
    # GNU/ELF only. Apple's Mach-O linker does not implement
    # -Bsymbolic-functions, so Darwin must use its normal two-level namespace.
    target_link_options(${CMAKE_PROJECT_NAME} PRIVATE -Wl,-Bsymbolic-functions)
endif()
''',
    "MobileGlues ELF-only symbolic linker option",
)

# MobileGlues 2.0 intentionally uses -O3 for GCC/Clang, but its compiler test
# excludes AppleClang and the final else forces -O2. Because add_compile_options
# appears after CMake's Release flags, that -O2 is the effective optimization
# level in the v2 iOS artifact. v3 makes AppleClang an explicit Release-quality
# path instead of silently overriding Release to -O2. ThinLTO remains enabled by
# the upstream block above this one.
patch_exact(
    CMAKE,
    '''if (CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang" AND NOT MATCHES "AppleClang")
    add_compile_options(-O3 -ffunction-sections -fdata-sections)
    add_link_options(-Wl,--gc-sections)
elif (CMAKE_CXX_COMPILER_ID MATCHES "MSVC")
#    add_compile_options(/O2)
else ()
    add_compile_options(-O2)
endif()
'''.replace("elif", "elseif"),
    '''if (CMAKE_CXX_COMPILER_ID STREQUAL "AppleClang")
    # Enhanced iOS/A13: do not let MobileGlues' generic fallback downgrade a
    # Release build to -O2. Keep the hot translation/draw paths at -O3.
    add_compile_options(-O3)
elseif (CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    add_compile_options(-O3 -ffunction-sections -fdata-sections)
    add_link_options(-Wl,--gc-sections)
elseif (CMAKE_CXX_COMPILER_ID MATCHES "MSVC")
#    add_compile_options(/O2)
else ()
    add_compile_options(-O2)
endif()
''',
    "MobileGlues AppleClang -O3 release optimization",
)
