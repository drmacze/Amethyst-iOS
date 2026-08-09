# Amethyst Enhanced v2

`enhanced/v2` is the second performance-and-usability branch for this Amethyst
iOS fork. The primary validation target is Apple A13 / iPhone 11 running modern
Minecraft Java with Fabric + Sodium, then Iris/shader testing after the base
renderer is verified.

## Renderer and build baseline

Enhanced v2 keeps the v1 renderer baseline and makes the A13 artifact explicit:

- Keep current AngelAura Amethyst launcher/JIT/runtime fixes.
- Build Amethyst native code with `RELEASE=1`.
- Pin MobileGlues to upstream **2.0.0** commit
  `fbc4e412e353302607ba36489b2dd573b5becb25`.
- Build MobileGlues in **Release** and use its supported IPO/ThinLTO path.
- Adapt Amethyst to the MobileGlues 2.x `MobileGlues-cpp` source layout and
  static SPIRV-Cross configuration.
- Compile the v2 A13 artifact with `-mcpu=apple-a13` for both Amethyst and
  MobileGlues, while keeping the CMake CPU target configurable.
- In the Enhanced build, renderer `Auto` resolves to MobileGlues instead of the
  upstream ANGLE fallback so the renderer being optimized is actually used.

This does not claim a specific FPS uplift until an identical-world A/B benchmark
has been run on the target device.

## iOS memory governor

Upstream Auto RAM is based only on a percentage of physical device memory.
Enhanced v2 keeps that value as an upper bound, but also asks iOS for the current
per-process allocation headroom with `os_proc_available_memory()` and reserves a
dynamic native margin for Metal, MobileGlues, LWJGL, JVM native allocations and
the launcher. The selected values are logged as `[EnhancedMemory]`.

The purpose is sustained performance and fewer jetsam/native-memory failures,
not maximizing the Java `-Xmx` number.

## Content Hub

Enhanced v2 adds a launcher-native Content Hub. It installs content into the
currently selected profile instead of requiring Files.app directory work.

### Providers

**Modrinth** works without a user API token and supports:

- Mods
- Modpacks
- Resource packs
- Shaders

Search requests are filtered against the selected Minecraft version. Mod search
also uses the selected profile's loader when it can be resolved (Fabric, Quilt,
Forge or NeoForge).

**CurseForge** support is implemented through the documented authenticated REST
API. CurseForge requires an approved `x-api-key`, so Enhanced does not ship a
shared/unapproved key. A user/developer key can be entered from Content Hub and
is stored in launcher preferences without being logged.

CurseForge content classes/categories are discovered from the API at runtime;
v2 intentionally does not depend on guessed historical class IDs. This enables
Mods, Modpacks, Resource/Texture Packs, Shaders and Worlds when CurseForge's
Minecraft taxonomy exposes the corresponding class/category.

### Automatic destinations

For the active profile, Content Hub installs to standard Minecraft locations:

- Mods -> `mods/`
- Resource packs -> `resourcepacks/`
- Shaders -> `shaderpacks/`
- Worlds -> `saves/`

Modrinth modpacks reuse Amethyst's existing Modrinth pack installer. CurseForge
modpacks use `manifest.json`, resolve referenced project/file IDs through the
CurseForge API, download provider-approved files, extract the pack's overrides,
and create the launcher profile metadata. Fabric/Quilt loader metadata can be
installed directly; Forge/NeoForge still rely on Amethyst's corresponding loader
installation support when the loader is not already present.

### Safety and management

- Provider SHA-1 hashes are passed through Amethyst's existing verified download
  pipeline when available.
- World ZIP extraction rejects absolute paths and `..` traversal before writing.
- Save folders get unique names instead of overwriting an existing world.
- Content Hub records files/folders it installed in
  `.amethyst/content-index.json` for launcher-side uninstall.
- Uninstall refuses to remove paths outside the active profile directory.
- Direct HTTPS import is available for single-file mods, resource packs, shaders
  and worlds.
- Direct URL modpack import is deliberately blocked because a pack must process
  dependencies and loader/profile metadata rather than merely unzip files.
- No scraping-only third-party content sites are built in. Providers should have
  a stable documented API or be used through explicit direct-file import.

## Validation order

1. Install the v2 IPA and confirm the launcher reaches the existing profile list.
2. Launch Minecraft with Fabric + Sodium and no shader; record FPS, 1% lows or
   frametime behavior, memory log and device temperature in a fixed test scene.
3. Open Content Hub, install one Modrinth shader and resource pack, confirm they
   land in the active profile and Minecraft sees them.
4. Install one mod matching the active Minecraft/Fabric version.
5. Add Iris with shaders disabled, then enable one lightweight shader.
6. Only after correctness is established, compare MobileGlues v2 against Zink
   using identical world/settings and tune renderer-specific switches.

Performance changes should be kept only when they improve measurable FPS,
frametime stability, load time or memory behavior without adding rendering
errors or native crashes.
