# Meridian umbrella

The build entry point for **Meridian** — a modular MITM proxy for Hytale whose pieces (proxy,
launcher, protocol, core, and the modules) each live in their own repo. One command clones every
component and builds a coherent, runnable set for a given **game version**, in dependency order into
a per-version Maven repo (`.m2/<ver>`) so different game versions never clobber each other.

## Requirements

JDK 22, Maven, and git. The script is bash: native on Linux/macOS; on Windows run it under **Git
Bash** or **WSL** (not cmd/PowerShell). The build *output* is cross-platform — the proxy uber-jar
bundles the native QUIC libs for linux/osx/windows × x86_64/aarch_64, so one `dist/` jar runs on all
three OSes.

## Layout

```
meridian/
  build.sh                     the orchestrator
  versions/<game>.conf         the COMPLETE recipe for that game version (see below)
  checkouts/<name>/            components cloned from git URLs (generated, gitignored)
  .m2/<game>/                  isolated Maven repo (generated)
  dist/<game>/                 output: proxy jar, launcher jar, modules/ (generated)
```

Each **`versions/<game>.conf` is the whole recipe** — a `crc` line plus one line per component:

```
crc 1316766548
#  <name>                  <source: git-url | local path>                   [branch]
meridian-protocol          git@github.com:hyspy-dev/meridian-protocol.git   line/0.5.9
meridian-core              git@github.com:hyspy-dev/meridian-core.git       line/0.5.9
meridian-proxy             git@github.com:hyspy-dev/meridian-proxy.git      main
meridian-xray              git@github.com:hyspy-dev/meridian-xray.git       main
…
```

A component listed is built; one that isn't, isn't — there are no on/off flags, so to drop something
from a version you just leave its line out. The five core components (api, protocol, core, proxy,
launcher) build in dependency order; every other line is a module.

**The branch column decides how a source is used** — not whether it's a git URL or a local path:

- **branch given** → a clean isolated checkout in `checkouts/<name>`: the source (git URL *or* local
  path) is cloned, `git fetch`ed every build to stay fresh, then `<branch>` is checked out — any
  working-tree edits in the source are discarded. Your own repos are never touched.
- **local path, no branch** → the folder is built in place, exactly as it sits: no clone, no fetch,
  no branch switch — you drive it.
- **git URL, no branch** → same as a branch, following the remote's default (`origin/HEAD`).

Local paths are absolute or relative to this umbrella dir.

So a fresh `git clone` of just this umbrella + `./build.sh <ver>` bootstraps the whole set into
`checkouts/`, and building one version never disturbs your working trees or another version's build.

**Recipe resolution.** `./build.sh <ver>` uses `versions/<ver>.conf` if it exists, else falls back to
the wildcard `versions/<major>.<minor>.X.conf` — one recipe for a whole minor line that shares a
protocol. So `build 0.5.9` and `build 0.5.7` both hit `0.5.X.conf`, and `build 0.6.0-pre.13` (pre
included) hits `0.6.X.conf`. If one specific patch changes the wire protocol, drop an exact
`versions/<ver>.conf` for it — the exact file always wins.

## Build

```sh
./build.sh 0.6.0-pre.13
```

Result:

```
dist/0.6.0-pre.13/
  meridian-proxy-*-all.jar         runnable proxy (uber-jar)
  meridian-launcher-*.jar          runnable launcher
  modules/*.jar                    every module in the recipe that builds for this version
```

**Rebuild one component** (fast iteration) — pass its name as a second arg:

```sh
./build.sh 0.6.0-pre.13 meridian-launcher     # builds only the launcher, replaces its jar in dist/
```

It uses that component's recipe entry (source/branch), builds just it, and leaves the rest of `dist/`
untouched. Its dependencies must already be in `.m2/<ver>` — run a full `./build.sh <ver>` once first.

Run the launcher jar and it drives the proxy; or run the proxy jar standalone.

## Per-version source (`line/<game-version>` branches)

The only thing that differs per game version is the **protocol**, plus the few files that use
protocol features a given version lacks. Those live on a `line/<game-version>` branch in the repo
that needs them — you point that component's `branch` column at it in the version's recipe (e.g. for
0.5.9, `line/0.5.9` on meridian-protocol, meridian-core, meridian-client-control and
meridian-world-downloader; the proxy and everything else stay `main`, since the proxy source is
protocol-neutral). Module builds are best-effort: one that can't compile against the target protocol
is skipped with a note, not fatal.

---

## Third-party modules — where they go, and does `build <ver>` pick them up?

Two perspectives.

### If you're writing a module

A module is its **own repo**, not part of this umbrella. You build it against the **SDK**
(`meridian-api`, and `meridian-core-api` if you use core services) — never against
`meridian-protocol` directly (the enforcer bans that; a protocol dep would tie you to one game
version). Because a Layer-2 module touches only the protocol-neutral SDK, **the jar is
game-independent: build it once, it runs on every game version.**

You have two ways to get the SDK to compile against:

1. **From this umbrella (no token).** Run `./build.sh <ver>` once — it installs `meridian-api` into
   `.m2/<ver>`. Point your module's build at that repo:
   `mvn -Dmaven.repo.local=/path/to/meridian/.m2/<ver> package`.
2. **From GitHub Packages** (needs a personal access token with `read:packages`) — the normal
   published-dependency route, independent of this repo.

Then to **run** it: drop your jar into the proxy's module folder. The proxy loads modules per
server from `<host_port>/modules/`, falling back to its default `modules/` for a new server, and
renders your `SettingsSpec` in its UI. That's the runtime contract — the launcher (as package
manager) can also place/enable it for you.

### Does it appear in `dist/<ver>/` after `build <ver>`?

**Only if it's listed** in the version's recipe (`versions/<ver>.conf`). Append a line — the branch
column decides how your source is used:

```
my-radar    https://github.com/you/meridian-radar.git   main   # git URL + branch: clone into checkouts/, fetch, checkout main
my-mod      ../my-mod                                    dev    # local repo + branch: clone into checkouts/ at 'dev' (working-tree edits discarded)
my-mod      ../my-mod                                           # local path, no branch: build the folder in place, as-is
```

…and `./build.sh <ver>` builds it against the same `.m2/<ver>` SDK and drops the jar into
`dist/<ver>/modules/` next to the official ones. So:

- **Not listed** → `build <ver>` ignores it. Build+drop the jar yourself as above.
- **Listed** → built and bundled by `build <ver>`, working immediately (it only needs the SDK the
  build already produced). Use the no-branch local form while you're iterating on your working tree;
  add a branch once you want a clean, reproducible checkout.

The official rows are the maintainers' set — a third-party dev appends their own row, or just drops
the built jar into the proxy's module folder at runtime. (Curated/one-click distribution through the
launcher is planned; for now, add a row or drop the jar.)
