# Amethyst Enhanced v4

`enhanced/v4` is the Apple-graphics/runtime modernization branch. It retains the v3.1 Content Hub, safe cache manager, A13 code generation, headroom-aware RAM policy and game-session cleanup, while replacing the oldest graphics components with pinned modern builds and adding a version-aware LWJGL runtime for Minecraft 26.x.

The primary device is Apple A13 / iPhone 11. Build success is not treated as proof of GPU correctness: new Zink/MoltenVK and Minecraft 26.x paths remain explicit/diagnostic until a physical-device launch has been tested.

## Stable-first graphics policy

Enhanced v4 deliberately does **not** mean "follow every upstream main branch". The graphics stack is pinned so an IPA can be reproduced, and stable/bug-fix releases are preferred when a newer development release exists.

### MobileGlues Enhanced

- Pinned core commit: `fbc4e412e353302607ba36489b2dd573b5becb25`.
- Release + ThinLTO/IPO where supported.
- AppleClang `-O3` path and `-mcpu=apple-a13` for the A13 artifact.
- Persistent, renderer-versioned GLSL cache under `<POJAV_HOME>/.amethyst/mobileglues/2.0.0/`.
- Remains the Enhanced `Auto` renderer until on-device measurements prove another backend is both faster and safer.

### Zink Modern

A second Zink entry is added instead of overwriting the known recovery renderer:

- **Zink Modern — Mesa 26.1.6 / MoltenVK 1.4.2** -> `libOSMesaModern.8.dylib`
- **Zink Legacy — Mesa 21 recovery** -> original `libOSMesa.8.dylib`

Mesa 26.1.6 is used because it is the current 26.1 bug-fix line selected for stability; the newer 26.2.0 line is not used as the v4 baseline while it is the new development series. Modern Mesa is built Release/O3 for arm64 A13 with Gallium Zink and OSMesa, LLVM disabled, and a dedicated disk shader cache under `<POJAV_HOME>/.amethyst/mesa/26.1.6/`.

Zink Modern remains opt-in initially. Amethyst's OSMesa presentation bridge still has different performance characteristics from the direct Metal/ANGLE path, and a modern driver does not by itself prove that every A13 pipeline/vertex-format case is fixed.

### MoltenVK 1.4.2

The modern Vulkan-on-Metal path is rebuilt against MoltenVK 1.4.2. The previous MoltenVK binary is preserved as a legacy copy for the old Zink recovery path where direct linkage allows it. iOS 15+ is the v4 graphics-stack deployment floor.

### ANGLE Metal

ANGLE is rebuilt for iOS arm64 from Chromium branch `chromium/7871`, with Metal enabled and unused desktop/D3D/SwiftShader/Vulkan backends disabled. A shipping Chromium stable branch is used rather than arbitrary ANGLE `main` so the renderer is reproducible and closer to a production-tested branch.

This also upgrades the GLES implementation available to MobileGlues when its ANGLE-backed mode is enabled.

## Minecraft 1.21.11 -> 26.x dual LWJGL runtime

A single global LWJGL upgrade is unsafe. Minecraft 1.21.11 still uses older 3.3.x APIs, including STB APIs that changed in newer LWJGL, while Minecraft 26.x requires the newer 3.4.x module set.

v4 therefore carries two isolated launcher runtimes:

- `lwjgl-legacy.jar` + the existing root iOS natives for the established 3.3.x path;
- `lwjgl-modern-3.4.1.jar` + `Frameworks/lwjgl-modern/` built from `AngelAuraMC/lwjgl3:wip/rebase_3.4.1` for modern Minecraft.

The modern iOS build enables the modules required by Mojang's newer native bootstrap, including SPVC, shaderc, VMA and Vulkan. At launch, Enhanced inspects the version metadata for `org.lwjgl:lwjgl:<version>`. LWJGL >= 3.4.1 selects the modern runtime. Java 25 is used as a conservative fallback signal for inherited/custom 26.x metadata that omits the base LWJGL declaration.

The Java bootstrap classpath no longer relies on wildcard ordering to choose between incompatible LWJGL APIs. It explicitly excludes every generic `lwjgl*.jar` and then appends exactly one versioned runtime. Modern native libraries are likewise kept in a separate directory and selected with `org.lwjgl.librarypath`, so an older Minecraft session cannot accidentally bind to a newer STB/core dylib.

This directly addresses the current Minecraft 26.2 startup blocker where Amethyst's bundled 3.3.3 path lacks `org.lwjgl.util.spvc.Spvc`. It does **not** claim that every future 26.x snapshot is automatically guaranteed: Mojang may raise Java/JNA/LWJGL requirements again, and future metadata must still be validated.

## JNA policy

Enhanced does not blindly replace Mojang's newer JNA Java artifact with the newest available release. JNA's Java/native ABI is version-sensitive. Existing Amethyst logic allows newer Mojang JNA versions instead of forcing the older 5.13 jar, and v4 keeps that behavior while the exact iOS native compatibility is validated from device logs. If a future Minecraft release raises the required native ABI, the correct fix is an exact-version signed iOS native runtime, not an unrelated newer `libjnidispatch` dropped into the sandbox.

## Performance and system work retained

- Native Amethyst/MobileGlues A13 code generation.
- `os_proc_available_memory()` based Auto RAM governor with native reserve.
- Thermal-state and Low Power Mode diagnostics.
- Persistent renderer caches with explicit safe reset support.
- `CADisplayLink`, controller, mouse, Core Motion and audio cleanup when leaving the game.
- Lazy Metal HUD loading.
- Content Hub for Modrinth/CurseForge/direct content installation.
- Safe ZIP/modpack path validation and content-management uninstall boundaries.
- Clear Renderer Cache, Clear Launcher Cache and Clear All Safe Cache; worlds/mods/resource packs/shader packs/profiles/accounts/runtimes are outside the deletion set.

## Validation matrix

### Minecraft 1.21.11

1. Fabric + Sodium, MobileGlues, no shader.
2. Repeat launch and cache-hit launch.
3. Iris with shader disabled.
4. Lightweight Iris shader on MobileGlues.
5. Zink Modern no shader, then Iris only if the base world is correct.
6. Zink Legacy remains the recovery comparison.

### Minecraft 26.x

1. Vanilla with Java 25 and the modern LWJGL runtime; confirm SPVC/shaderc/VMA/Vulkan bootstrap completes.
2. Confirm no 3.3.x LWJGL class/native is selected by mistake.
3. MobileGlues baseline before introducing Fabric or shader mods.
4. Only then test loader/mod compatibility for the exact 26.x build.

### A13 performance

Compare identical world, resolution, render distance, FPS cap, mods, Low Power Mode and thermal state. Record average FPS, frametime spikes/1% lows, renderer cache cold/hit behavior, memory headroom, temperature/throttling and any native GPU error. No renderer becomes the new automatic default solely because it has a newer version number.

## Fail-safe rule

The goal is a launcher that fails safely rather than pretending every new Minecraft or driver revision is compatible. Legacy Zink is preserved; MobileGlues remains Auto; Modern Zink is opt-in; LWJGL is selected by game metadata; and missing modern runtime files cause an explicit launcher error instead of falling back silently to an ABI-mismatched library.
