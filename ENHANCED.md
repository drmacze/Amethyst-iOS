# Amethyst Enhanced v3

`enhanced/v3` builds on the v2 Content Hub and A13 baseline, but its priority is
now **sustained performance, repeat-launch stability, and fixing launcher/runtime
work that can quietly waste memory or CPU**. The primary validation target is an
Apple A13 / iPhone 11 running modern Minecraft Java with Fabric + Sodium, then
Iris/shaders after the base renderer is stable.

No fixed FPS uplift is claimed here. Performance changes stay only when an
identical-world/on-device A/B test shows better FPS, frametime stability, loading
behaviour, memory behaviour, or sustained thermals without new rendering errors.

## v3 performance changes

### MobileGlues 2.0 + A13 build path

- Pin MobileGlues to upstream **2.0.0** commit
  `fbc4e412e353302607ba36489b2dd573b5becb25` for reproducible renderer behaviour.
- Build Amethyst and MobileGlues for `arm64` with `-mcpu=apple-a13`.
- Build MobileGlues as **Release** with its supported ThinLTO/IPO path.
- Correct MobileGlues' AppleClang optimization branch: upstream's compiler test
  excludes AppleClang from the `-O3` path and its final fallback adds `-O2`.
  Enhanced v3 explicitly keeps the iOS Release renderer at `-O3`.
- Keep the Darwin/Mach-O compatibility patches required by MobileGlues 2.0:
  ARB forwarding wrappers instead of ELF aliases, Darwin thread IDs instead of
  Linux `__NR_gettid`, and no GNU `-Bsymbolic-functions` on Apple's linker.
- Enhanced `Auto` renderer continues to resolve to MobileGlues so the optimized
  renderer is the path actually exercised.

### Persistent iOS MobileGlues shader cache

MobileGlues' upstream default state directory is `/sdcard/MG`, which is an
Android path. Enhanced v3 assigns a writable, launcher-global directory before
the renderer is loaded:

`<POJAV_HOME>/.amethyst/mobileglues/2.0.0/`

This lets MobileGlues' `glsl_cache.tmp` survive normal iOS launches and lets
profiles using the same pinned renderer reuse identical translated shader
sources. A launcher-global path also avoids a profile switch in the same process
leaving `MG_DIR_PATH` attached to whichever profile launched first.

The directory is versioned because the cache key is based on shader source and
the cache file has no translator-version header; a future renderer should not
silently consume translations produced by an older MobileGlues build. An
explicit user-provided `MG_DIR_PATH` is respected. The launcher logs the selected
directory and existing cache size as `[EnhancedRenderer]` diagnostics.

### iOS memory governor and diagnostics

Enhanced keeps the v2 Auto RAM governor. Physical RAM is an upper bound, while
`os_proc_available_memory()` supplies current process headroom and the launcher
reserves native memory for Metal, MobileGlues, LWJGL, JIT code and other JVM
native allocations before selecting Java `-Xmx`.

At launch v3 also logs iOS thermal state and Low Power Mode under
`[EnhancedPerf]`. These are diagnostic inputs for A/B tests rather than magic
performance switches.

### Game-session lifecycle cleanup

Upstream creates a `CADisplayLink` that drives gyro/controller ticks and stores
block-based mouse/controller notification observer tokens. Enhanced v3 gives the
display link an owner and explicitly cleans the game session before replacing
the root view controller:

- invalidate the input `CADisplayLink`;
- remove mouse/controller notification observers;
- clear mouse handlers and unregister controller callbacks;
- stop Core Motion gyro updates;
- restore the iOS idle timer;
- deactivate the game audio session and notify other audio sessions;
- make cleanup idempotent and keep `dealloc` as a fallback.

This prevents old game surfaces from continuing input work or being retained by
observer/display-link relationships after returning to the launcher.

### Lazy performance HUD support

The private Metal HUD helper dylib is no longer loaded unconditionally on every
game launch. Enhanced v3 loads it only when the user actually enables the
performance HUD.

## v3 system/reliability fixes

### Hardened modpack installation

Modpack file paths are now treated as untrusted input. Modrinth pack files and
ZIP override extraction reject absolute paths, home-prefixed paths and `..`
traversal, standardize the destination, and require every output to remain below
the intended pack directory.

The legacy Modrinth detail loader also no longer writes into empty mutable arrays
by index; it appends normalized version data instead. Installed Modrinth profiles
are saved explicitly after creation.

### Content Hub retained from v2

Content Hub still supports launcher-native discovery/installation for:

- Modrinth: mods, modpacks, resource packs, shaders;
- CurseForge: authenticated discovery/install where its Minecraft taxonomy and
  third-party download permissions allow it;
- direct HTTPS import for single-file mods, resource packs, shaders and worlds;
- automatic profile destinations (`mods`, `resourcepacks`, `shaderpacks`,
  `saves`);
- launcher-side installed-content registry/uninstall;
- protected world ZIP extraction and unique save-folder naming.

CurseForge continues to require a user/developer approved `x-api-key`; Enhanced
does not embed or share an unauthorized provider key.

## Validation order

1. Install the v3 IPA over v2 and confirm existing profiles, worlds, controls and
   Content Hub state remain accessible.
2. Launch Fabric + Sodium with no shader in a fixed world. Record FPS/frametime,
   `[EnhancedMemory]`, `[EnhancedPerf]`, temperature and stability.
3. Quit back to the launcher and launch the same profile repeatedly. Confirm old
   input/gyro/audio work does not survive between sessions.
4. After the first renderer run, confirm
   `<POJAV_HOME>/.amethyst/mobileglues/2.0.0/glsl_cache.tmp` exists; compare a cold
   launch with a cache-hit launch and try a second profile using the same shader.
5. Test Content Hub shader/resource-pack installation and one Modrinth modpack.
6. Add Iris with shaders disabled, then a lightweight shader.
7. Compare MobileGlues v3 against the previous v2 artifact and Zink using the
   same world, resolution, render distance, mods and power/thermal conditions.

Do not tune MobileGlues multi-draw ordering from guesses. MobileGlues 2.0 contains
capability-aware backend selection and a benchmark facility; A13-specific order
changes should follow device measurements rather than hard-coded assumptions.
