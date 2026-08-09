# Amethyst Enhanced

`enhanced/a13-performance-v1` is the first performance-focused branch for the
Amethyst iOS fork. The immediate test target is iPhone 11 / Apple A13 running
Minecraft Java 1.21.11 with Fabric and Sodium, with Iris compatibility tested
after the base renderer is proven correct.

## v1 baseline

This branch deliberately starts from measurable, low-risk changes rather than
adding random JVM flags:

- Keep current AngelAura Amethyst `main` launcher/JIT/runtime fixes.
- Build Amethyst native code with `RELEASE=1`.
- Pin MobileGlues to upstream **2.0.0** commit
  `fbc4e412e353302607ba36489b2dd573b5becb25`.
- Adapt Amethyst CI to the MobileGlues 2.x `MobileGlues-cpp` source layout.
- Configure MobileGlues as **Release**, allowing its non-Debug IPO/ThinLTO path
  when supported by the Apple toolchain.
- Use the MobileGlues 2.x static SPIRV-Cross configuration instead of copying
  the obsolete standalone SPIRV-Cross dylib.
- Build a full iOS IPA on a GitHub-hosted macOS runner and publish it as
  `Amethyst-Enhanced-A13-iOS.ipa`.

## Why MobileGlues 2.0 first

MobileGlues 2.0 contains renderer-side performance work directly relevant to
Minecraft workloads: reduced redundant GL state changes, lower driver-query
overhead, persistent scratch storage for base-vertex drawing, optimized
multi-draw paths, cheaper framebuffer state handling, and less expensive GLSL
cache persistence during shader-pack loading.

The goal of v1 is to establish a reproducible optimized baseline. It does **not**
claim that every Iris shader is fixed on Apple A13 yet.

## Test order

1. Minecraft 1.21.11 + Fabric + Sodium, no Iris, no resource pack.
2. Confirm world rendering correctness, FPS, frametime and temperature.
3. Add Iris with shaders disabled.
4. Add one known-light shader and collect both Amethyst and MobileGlues logs.
5. Only after correctness is established, tune A13-specific renderer paths.

## Planned next stages

- Verify/fix Minecraft 1.21.11 LWJGL/STB compatibility on the current Amethyst
  runtime before attributing image-processing errors to the renderer.
- Replace fixed-percent Auto RAM with an iOS memory-headroom-aware policy.
- Add an explicit A13 performance profile instead of unsafe global defaults.
- Investigate Iris shader translation failures on Apple GPUs with captured
  shader/compiler logs.
- Benchmark Zink versus MobileGlues Enhanced using identical worlds/settings.

Performance changes should be retained only when they improve measurable FPS or
frametime without introducing rendering errors or additional native crashes.
