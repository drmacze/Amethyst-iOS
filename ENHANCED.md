# Amethyst Enhanced v3.1

`enhanced/v3` builds on the v2 Content Hub and A13 baseline, with priority on **sustained performance, repeat-launch stability, renderer cache behaviour, and launcher/runtime reliability**. The primary validation target is Apple A13 / iPhone 11 running modern Minecraft Java with Fabric + Sodium, followed by Iris/shader testing once the base renderer is stable.

No fixed FPS uplift is claimed without identical-world, on-device A/B testing.

## Performance baseline

- MobileGlues is pinned to upstream **2.0.0** commit `fbc4e412e353302607ba36489b2dd573b5becb25` for reproducible renderer behaviour.
- Amethyst and MobileGlues are built for arm64 with `-mcpu=apple-a13`.
- MobileGlues is built as Release with ThinLTO/IPO, and Enhanced corrects its AppleClang path so the iOS renderer keeps `-O3` instead of falling through to `-O2`.
- Darwin/Mach-O compatibility fixes remain: ARB forwarding wrappers instead of ELF aliases, Darwin thread IDs instead of Linux `__NR_gettid`, and no GNU `-Bsymbolic-functions` on Apple's linker.
- Enhanced Auto renderer resolves to MobileGlues.

## Persistent MobileGlues shader cache

MobileGlues' Android default `/sdcard/MG` is replaced with the writable launcher-global directory:

`<POJAV_HOME>/.amethyst/mobileglues/2.0.0/`

This lets `glsl_cache.tmp` survive launches and allows profiles using the same pinned renderer to reuse identical translated shader sources. The directory is renderer-versioned so future translator versions do not silently reuse stale translations.

## v3.1 Clear Cache manager

A new **Clear Cache** entry is available directly from the launcher sidebar. It reports current cache sizes before deletion and exposes three safe operations:

- **Renderer Cache** — removes only MobileGlues shader/pipeline cache files. It also writes a reset marker so the cache is removed again before a later cold renderer launch; this avoids an already-loaded MobileGlues singleton restoring stale in-memory cache state after the user returns from Minecraft.
- **Launcher Cache** — clears the app's `NSCachesDirectory` contents and `NSURLCache` network responses.
- **Clear All Safe Cache** — performs both operations together.

The cache manager intentionally does **not** delete worlds, mods, modpacks, resource packs, shader-pack ZIPs, profiles, controls, accounts, game assets, Java runtimes, or Minecraft version files. Renderer-cache actions tell the user to close and reopen Amethyst before the next Minecraft launch for a deterministic fresh renderer state.

## iOS memory governor and diagnostics

Auto RAM uses physical memory only as an upper bound. `os_proc_available_memory()` supplies current process headroom, while native memory is reserved for Metal, MobileGlues, LWJGL, JIT code and JVM native allocations before selecting Java `-Xmx`.

Launch logs also include `[EnhancedPerf]` thermal state and Low Power Mode information for reproducible A/B tests.

## Game-session lifecycle cleanup

Enhanced owns and invalidates the `CADisplayLink` that drives gyro/controller ticks, removes block-based mouse/controller observers, clears input handlers, unregisters controller callbacks, stops Core Motion, restores the idle timer, and deactivates the game audio session before returning to the launcher. Cleanup is idempotent and also runs from `dealloc` as a fallback.

The private Metal HUD helper library is loaded only when the performance HUD is actually enabled.

## Installer/system reliability

Modpack file paths are treated as untrusted input. Modrinth pack files and ZIP override extraction reject absolute paths, home-prefixed paths and `..` traversal, standardize destinations, and require outputs to stay inside the intended pack directory. The legacy Modrinth detail loader appends to mutable arrays correctly and generated profiles are explicitly saved.

## Content Hub retained from v2

Content Hub continues to support Modrinth mods/modpacks/resource packs/shaders, CurseForge authenticated discovery/install where allowed, direct HTTPS import for individual content, automatic profile destinations, and launcher-side installed-content management. CurseForge still requires a user/developer approved `x-api-key`; Enhanced does not embed an unauthorized shared key.

## Validation order

1. Install the v3.1 IPA over v3 and confirm existing profiles/worlds/controls remain accessible.
2. Open **Clear Cache** and verify the displayed sizes; clear Launcher Cache and confirm launcher operation remains normal.
3. Launch Fabric + Sodium without shaders, quit to launcher, clear Renderer Cache, fully close/reopen Amethyst, then relaunch the same scene.
4. Confirm `[EnhancedCache]`, `[EnhancedMemory]`, `[EnhancedRenderer]` and `[EnhancedPerf]` logs behave as expected.
5. Compare cold renderer launch vs cache-hit launch in an identical world.
6. Add Iris with shaders disabled, then test a lightweight shader.
7. Compare v3.1 against v3/v2 and Zink under the same resolution, render distance, mods, power state and thermal conditions.

Do not hard-code MobileGlues multi-draw ordering from guesses. MobileGlues 2.0 includes capability-aware selection and a benchmark facility; A13-specific ordering should follow measured device results.
