#!/usr/bin/env python3
"""Apply minimal Darwin/iOS build fixes to pinned MobileGlues 2.0.0.

Keep this patch intentionally narrow. Upstream 2.0.0 contains three ELF-style
function aliases added in framebuffer.cpp. Clang on Darwin rejects
__attribute__((alias)), so export equivalent forwarding functions instead.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FB = ROOT / "Natives" / "external" / "MobileGlues" / "MobileGlues-cpp" / "gl" / "framebuffer.cpp"

text = FB.read_text(encoding="utf-8")

old = '''extern "C" {
GLAPI GLAPIENTRY void glDeleteFramebuffersARB(GLsizei n, const GLuint* names) __attribute__((alias("glDeleteFramebuffers")));
GLAPI GLAPIENTRY void glFramebufferRenderbufferARB(GLenum target, GLenum attachment, GLenum renderbuffertarget,
                                                   GLuint renderbuffer) __attribute__((alias("glFramebufferRenderbuffer")));
GLAPI GLAPIENTRY void glFramebufferTextureLayerARB(GLenum target, GLenum attachment, GLuint texture, GLint level,
                                                   GLint layer) __attribute__((alias("glFramebufferTextureLayer")));
}
'''

new = '''extern "C" {
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
'''

if old not in text:
    if new in text:
        print("MobileGlues Darwin alias patch already applied")
        raise SystemExit(0)
    raise SystemExit("patch_mobileglues_ios: expected MobileGlues 2.0 alias block not found")

FB.write_text(text.replace(old, new, 1), encoding="utf-8")
print("Patched MobileGlues framebuffer ARB exports for Darwin/Mach-O")
