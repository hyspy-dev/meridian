#!/usr/bin/env bash
# Meridian umbrella build — one self-contained recipe per game version.
#
#   ./build.sh <game-version>        reads versions/<game-version>.conf
#
# versions/<ver>.conf IS the whole recipe: a `crc` line plus one line per component
#
#     <name>   <source: git-url | local path>   [branch]
#
# A component listed here is built; one that isn't, isn't (no separate flags). The five core
# components (api, protocol, core, proxy, launcher) build in dependency order; every other line is a
# module built into dist/modules (best-effort — a module that won't compile against this protocol is
# skipped with a note). The BRANCH column decides how a source is used:
#
#   <source> <branch>   -> a clean isolated checkout in checkouts/<name>: the source (git-url OR a
#                          local path) is cloned, FETCHED every build to stay fresh, then <branch> is
#                          checked out. Working-tree edits in the source are discarded; your own repos
#                          are never touched.
#   <local-path>        -> (no branch) the folder is built in place, exactly as it sits — you drive
#                          it, git is not touched. Absolute, or relative to this umbrella dir.
#   <git-url>           -> (no branch) follows the remote's default branch (origin/HEAD).
#
# Builds go into an isolated .m2/<ver>, so game versions never clobber each other.
set -euo pipefail

GAME="${1:?usage: ./build.sh <game-version> [component]   (see versions/)}"
TARGET="${2:-}"   # optional: build only this one component (its deps must already be in .m2/<ver>)
UMBRELLA="$(cd "$(dirname "$0")" && pwd)"
# Recipe resolution: exact <GAME>.conf first, else the wildcard <major>.<minor>.X.conf — one recipe
# for a whole minor line that shares a protocol (0.5.9 -> 0.5.X; 0.6.0-pre.13 -> 0.6.X, pre included).
CONF="$UMBRELLA/versions/$GAME.conf"
if [ ! -f "$CONF" ]; then
  WILD="$UMBRELLA/versions/$(printf '%s' "$GAME" | cut -d. -f1,2).X.conf"
  if [ -f "$WILD" ]; then CONF="$WILD"; echo ">> no $GAME.conf — using wildcard $(basename "$WILD")"; fi
fi
[ -f "$CONF" ] || { echo "No recipe for $GAME (tried $GAME.conf and $(printf '%s' "$GAME" | cut -d. -f1,2).X.conf)"; echo "Available: $(ls "$UMBRELLA/versions" 2>/dev/null)"; exit 1; }

PROTOCOL_CRC="$(awk '$1=="crc"{print $2; exit}' "$CONF")"
[ -n "$PROTOCOL_CRC" ] || { echo "$CONF needs a  'crc <value>'  line"; exit 1; }

M2="$UMBRELLA/.m2/$GAME"
DIST="$UMBRELLA/dist/$GAME"
CHECKOUTS="$UMBRELLA/checkouts"
[ -z "$TARGET" ] && rm -rf "$DIST"   # a full build starts clean; a single-component build keeps the rest
mkdir -p "$M2" "$DIST/modules" "$CHECKOUTS"
CORE_ORDER="meridian-api meridian-protocol meridian-core meridian-proxy meridian-launcher"

# Optional ~/.m2 fallback for third-party RELEASES (fast offline rebuilds; NOT CI-faithful). Default off.
MVN_SETTINGS=()
if [ "${USE_M2_CACHE:-0}" = "1" ]; then
  SETTINGS="$UMBRELLA/.build-settings.xml"
  if command -v cygpath >/dev/null 2>&1; then M2URL="file:///$(cygpath -m "$HOME/.m2/repository")"; else M2URL="file://$HOME/.m2/repository"; fi
  cat > "$SETTINGS" <<EOF
<settings><profiles><profile><id>user-m2-fallback</id>
  <repositories><repository><id>user-m2-cache</id><url>$M2URL</url>
    <releases><enabled>true</enabled></releases><snapshots><enabled>false</enabled></snapshots></repository></repositories>
  <pluginRepositories><pluginRepository><id>user-m2-cache-plugins</id><url>$M2URL</url>
    <releases><enabled>true</enabled></releases><snapshots><enabled>false</enabled></snapshots></pluginRepository></pluginRepositories>
</profile></profiles><activeProfiles><activeProfile>user-m2-fallback</activeProfile></activeProfiles></settings>
EOF
  MVN_SETTINGS=(-s "$SETTINGS"); echo ">> USE_M2_CACHE=1: reusing ~/.m2 for third-party releases (NOT CI-faithful)"
fi

mvnw() { mvn -B -ntp "${MVN_SETTINGS[@]}" -Dmaven.repo.local="$M2" -Dmeridian.protocol.version="$PROTOCOL_CRC" "$@"; }

# version-conf lookups (skip the `crc` line and comments)
c_src()   { awk -v n="$1" '$1==n && $1!="crc" && $1!~/^#/ {print $2; exit}' "$CONF"; }
c_branch(){ awk -v n="$1" '$1==n && $1!="crc" && $1!~/^#/ {print $3; exit}' "$CONF"; }
c_names() { awk '$1!="crc" && $1!~/^#/ && NF>=2 {print $1}' "$CONF"; }

# Resolve a component to a directory. git-url -> checkouts/<name> (cloned, fetched, branch checked out
# fresh); local path -> used in place, git untouched. Echoes the dir (progress goes to stderr).
resolve() {   # <name>
  local name="$1" dir="" localpath="" origin="" src br; src="$(c_src "$name")"; br="$(c_branch "$name")"
  [ -n "$src" ] || { echo "  ! $name has no source in $(basename "$CONF")" >&2; return 1; }
  case "$src" in
    /*|~*)    localpath="$src" ;;                       # absolute local path
    ./*|../*) localpath="$UMBRELLA/$src" ;;             # relative local path (to the umbrella dir)
  esac
  if [ -n "$localpath" ] && [ -z "$br" ]; then
    # local path, no branch -> build the folder in place, exactly as it sits (your working tree)
    dir="$localpath"
    [ -d "$dir" ] || { echo "  ! $name local path not found: $dir" >&2; return 1; }
  else
    # branch given (git-url OR local path), or no branch on a git-url (follow the remote's default,
    # origin/HEAD): a clean isolated checkout in checkouts/<name>, fetched fresh — working-tree edits dropped.
    dir="$CHECKOUTS/$name"; origin="${localpath:-$src}"
    [ -d "$dir/.git" ] || { echo "  cloning $name from $origin" >&2; git clone --quiet "$origin" "$dir" >&2 || return 1; }
    # Re-point origin at the recipe's CURRENT source every build. Without this, a checkout cloned from
    # an earlier source (e.g. a git URL) would keep fetching from there even after the recipe switches
    # to your local repo — so your local commits would never show up (the copy would go stale).
    git -C "$dir" remote set-url origin "$origin" 2>/dev/null || git -C "$dir" remote add origin "$origin" 2>/dev/null || true
    git -C "$dir" fetch --quiet --tags --prune origin 2>/dev/null || echo "  ! fetch failed for $name (offline?) — using what's on disk" >&2
    if [ -z "$br" ]; then                                  # no branch -> the remote's default (origin/HEAD)
      git -C "$dir" remote set-head origin --auto >/dev/null 2>&1 || true
      br="$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
      : "${br:=main}"                                      # last-resort fallback if HEAD is undetermined
    fi
    git -C "$dir" checkout --quiet -B "$br" "origin/$br" 2>/dev/null \
      || git -C "$dir" checkout --quiet "$br" 2>/dev/null \
      || { echo "  ! cannot check out '$br' in $name" >&2; return 1; }
  fi
  echo "$dir"
}

listed() { c_names | grep -qx "$1"; }

# Make every built jar self-describing: the BUILD writes two facts into the module.json inside
# it (the author's sources are never touched, and nothing has to be declared by hand):
#
#   "builtFor":         the wire CRC of the recipe this jar was built with — always
#   "requiresProtocol": whether the module's pom really depends on meridian-protocol
#
# The two are independent on purpose: being built BY the 0.5.9 recipe is not the same as
# depending on the 0.5.9 protocol. A module with requiresProtocol=false loads on any proxy no
# matter which recipe produced it; one with true is only loaded by a proxy speaking builtFor.
JAR_TOOL="$(command -v jar || echo "${JAVA_HOME:-}/bin/jar")"
stamp_build_info() {   # <jar-in-dist> <module-source-dir>
  local jarfile="$1" srcdir="$2" tmp req=false
  grep -rq --include=pom.xml '<artifactId>meridian-protocol</artifactId>' "$srcdir" && req=true
  tmp="$(mktemp -d)"
  ( cd "$tmp" && "$JAR_TOOL" xf "$jarfile" module.json 2>/dev/null ) || true
  if [ -f "$tmp/module.json" ]; then
    # Drop any previous stamp (rebuilds, or a jar built by another recipe), then write ours.
    sed -i -e '/"builtFor"[[:space:]]*:/d' -e '/"requiresProtocol"[[:space:]]*:/d' "$tmp/module.json"
    sed -i "0,/{/s//{\\n  \"builtFor\": $PROTOCOL_CRC,\\n  \"requiresProtocol\": $req,/" "$tmp/module.json"
    ( cd "$tmp" && "$JAR_TOOL" uf "$jarfile" module.json )
  fi
  rm -rf "$tmp"
}

# Build one component the right way: core libs install to .m2; proxy/launcher package into dist/;
# anything else is a module -> dist/modules (best-effort). Old artifacts for THIS component are
# cleared first, so a single-component rebuild replaces cleanly even when its version string changed.
build_one() {
  local name="$1" dir
  case "$name" in
    meridian-api|meridian-protocol)
      dir="$(resolve "$name")" || return 1
      echo "== install $name"; mvnw -f "$dir/pom.xml" -DskipTests clean install ;;
    meridian-core)
      dir="$(resolve "$name")" || return 1
      echo "== install $name"; mvnw -f "$dir/pom.xml" -DskipTests clean install
      # core-impl is a loadable module (module.json + shaded core-api) other modules dependsOn.
      rm -f "$DIST"/modules/meridian-core-impl-*.jar
      while IFS= read -r j; do
        cp "$j" "$DIST/modules/"
        stamp_build_info "$DIST/modules/$(basename "$j")" "$dir/meridian-core-impl"
      done < <(find "$dir/meridian-core-impl/target" -maxdepth 1 -name 'meridian-core-impl-*.jar' \
               ! -name 'original-*' ! -name '*-sources.jar' ! -name '*-javadoc.jar') ;;
    meridian-proxy)
      dir="$(resolve "$name")" || return 1
      echo "== build   $name"; mvnw -f "$dir/pom.xml" -DskipTests clean package
      rm -f "$DIST"/meridian-proxy-*-all.jar
      find "$dir/meridian-proxy/target" -maxdepth 1 -name '*-all.jar' ! -name 'original-*' -exec cp {} "$DIST/" \; ;;
    meridian-launcher)
      dir="$(resolve "$name")" || return 1
      echo "== build   $name"; mvnw -f "$dir/pom.xml" -DskipTests clean package
      rm -f "$DIST"/meridian-launcher-*.jar
      find "$dir/target" -maxdepth 1 -name 'meridian-launcher-*.jar' \
           ! -name 'original-*' ! -name '*-sources.jar' ! -name '*-javadoc.jar' -exec cp {} "$DIST/" \; ;;
    *)  # a module
      dir="$(resolve "$name")" || { echo "  ~ SKIP $name — cannot resolve"; SKIPPED="$SKIPPED $name"; return 0; }
      echo "== module  $name"
      if mvnw -f "$dir/pom.xml" -DskipTests clean package; then
        while IFS= read -r j; do
          cp "$j" "$DIST/modules/"
          stamp_build_info "$DIST/modules/$(basename "$j")" "$dir"
        done < <(find "$dir/target" -maxdepth 1 -name '*.jar' \
                 ! -name '*-sources.jar' ! -name '*-javadoc.jar' ! -name 'original-*')
      else echo "  ~ SKIP $name — doesn't build against $GAME (protocol $PROTOCOL_CRC)"; SKIPPED="$SKIPPED $name"; fi ;;
  esac
}

SKIPPED=""
if [ -n "$TARGET" ]; then
  # single component — its deps must already be in .m2/<ver> from a full build
  listed "$TARGET" || { echo "! '$TARGET' is not in the recipe for $GAME. Lists: $(c_names | tr '\n' ' ')"; exit 1; }
  echo ">> Meridian build $GAME / just $TARGET (protocol CRC $PROTOCOL_CRC) -> $DIST"
  build_one "$TARGET"
else
  echo ">> Meridian build $GAME (protocol CRC $PROTOCOL_CRC) -> $DIST"
  for name in $CORE_ORDER; do listed "$name" && build_one "$name"; done       # core, in dependency order
  for name in $(c_names); do                                                   # then modules
    case " $CORE_ORDER " in *" $name "*) continue ;; esac
    build_one "$name"
  done
fi
[ -n "$SKIPPED" ] && echo ">> Skipped:$SKIPPED"

echo ">> Done. dist/$GAME:"; ls -1 "$DIST" "$DIST/modules" 2>/dev/null
