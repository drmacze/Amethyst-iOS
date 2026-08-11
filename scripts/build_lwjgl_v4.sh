#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${RUNNER_TEMP:-/tmp}/amethyst-v4-lwjgl"
LWJGL_BRANCH="wip/rebase_3.4.1"
LEGACY_JARS="$ROOT/JavaApp/libs/lwjgl"
OTHER_JARS="$ROOT/JavaApp/libs/others"
MODERN_NATIVE="$ROOT/Natives/resources/Frameworks/lwjgl-modern"
rm -rf "$WORK"
mkdir -p "$WORK" "$OTHER_JARS" "$MODERN_NATIVE"

# actions/setup-java names these variables by runner architecture. The runtime
# being *built* is still iOS arm64; host JDK architecture only executes Ant.
JAVA8_HOME="${JAVA_HOME_8_ARM64:-${JAVA_HOME_8_X64:-$(/usr/libexec/java_home -v 1.8)}}"
JAVA25_HOME="${JAVA_HOME_25_ARM64:-${JAVA_HOME_25_X64:-$(/usr/libexec/java_home -v 25)}}"
export JAVA8_HOME
export JAVA_HOME="$JAVA25_HOME"
export PATH="$JAVA_HOME/bin:$PATH"

echo "JDK8:  $JAVA8_HOME"
echo "JDK25: $JAVA25_HOME"
"$JAVA8_HOME/bin/java" -version
"$JAVA25_HOME/bin/java" -version

echo "=== Enhanced v4: preserve legacy LWJGL Java API ==="
rm -rf "$WORK/legacy-classes"
mkdir -p "$WORK/legacy-classes"
for f in "$LEGACY_JARS"/lwjgl*.jar; do
  [[ -f "$f" ]] || continue
  (cd "$WORK/legacy-classes" && "$JAVA8_HOME/bin/jar" -xf "$f")
done
rm -rf "$WORK/legacy-classes/META-INF"
"$JAVA8_HOME/bin/jar" -cf "$OTHER_JARS/lwjgl-legacy.jar" -C "$WORK/legacy-classes" .
[[ -s "$OTHER_JARS/lwjgl-legacy.jar" ]]

echo "=== Enhanced v4: build AngelAura iOS LWJGL 3.4.1 ==="
git clone --depth 1 --branch "$LWJGL_BRANCH" https://github.com/AngelAuraMC/lwjgl3.git "$WORK/lwjgl3"
pushd "$WORK/lwjgl3"
bash ci_build_ios.bash

rm -rf "$WORK/modern-classes"
mkdir -p "$WORK/modern-classes"
while IFS= read -r -d '' f; do
  (cd "$WORK/modern-classes" && "$JAVA25_HOME/bin/jar" -xf "$f")
done < <(find bin/RELEASE -type f -name 'lwjgl*.jar' ! -name '*-sources.jar' ! -name '*-natives-*' -print0)
rm -rf "$WORK/modern-classes/META-INF"
"$JAVA25_HOME/bin/jar" -cf "$OTHER_JARS/lwjgl-modern-3.4.1.jar" -C "$WORK/modern-classes" .

rm -rf "$MODERN_NATIVE"
mkdir -p "$MODERN_NATIVE"
cp bin/out/*.dylib "$MODERN_NATIVE"/
popd

"$JAVA25_HOME/bin/jar" -tf "$OTHER_JARS/lwjgl-modern-3.4.1.jar" | grep -q '^org/lwjgl/util/spvc/Spvc.class$'
test -f "$MODERN_NATIVE/liblwjgl_spvc.dylib"
test -f "$MODERN_NATIVE/liblwjgl.dylib"
test -f "$MODERN_NATIVE/liblwjgl_stb.dylib"
test -f "$MODERN_NATIVE/liblwjgl_vma.dylib"
test -f "$MODERN_NATIVE/libshaderc.dylib"

printf '\n=== Enhanced v4 LWJGL verification ===\n'
ls -lh "$OTHER_JARS/lwjgl-legacy.jar" "$OTHER_JARS/lwjgl-modern-3.4.1.jar"
file "$MODERN_NATIVE"/*.dylib
for f in "$MODERN_NATIVE"/*.dylib; do
  echo "--- $f"
  otool -L "$f" || true
done

echo "Enhanced v4 dual LWJGL runtime prepared."
