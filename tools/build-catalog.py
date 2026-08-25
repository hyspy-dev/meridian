#!/usr/bin/env python3
"""Build the Meridian component catalog for the launcher.

Runs in the umbrella repo's `catalog.yml` workflow and writes a single static `catalog.json`,
deployed to GitHub Pages (never committed). The launcher fetches that one file from the CDN, so
it never touches the GitHub API (60 req/h unauthenticated limit).

Sources, in authority order:
  • Each component's releases. A release made by `release-component.yml` carries a CI-generated
    `meridian.json` manifest ({kind, version, builds:[{asset, sha256, size, proto?, games?,
    module?}]}) — the catalog is assembled from manifests alone, no jar downloads. Legacy
    releases without a manifest fall back to downloading the jar to hash it and read its
    `module.json` (cached by immutable asset id across runs).
  • The game→CRC map comes from meridian-protocol's own `line/<game>` branches — each branch's
    pom version IS the wire CRC (guarded in its build). The umbrella versions/*.conf plays no
    part here: it is a dev-mode override only.

Auth: uses $GITHUB_TOKEN (the workflow's default token → authenticated API reads, server-side
only). Release-asset downloads go to the CDN and need no auth.
"""

import datetime
import hashlib
import io
import json
import os
import re
import sys
import urllib.error
import urllib.request
import zipfile

ORG = os.environ.get("MERIDIAN_ORG", "hyspy-dev")
OUT = os.environ.get("CATALOG_OUT", "catalog.json")
PRIOR = os.environ.get("CATALOG_PRIOR", OUT)
TOKEN = os.environ.get("GITHUB_TOKEN")
API = "https://api.github.com"

# The framework itself — not user-installable modules. (meridian-core IS walked as a module:
# its release ships the loadable core-impl jar every Layer-2 module depends on.)
FRAMEWORK = {"meridian", "meridian-api", "meridian-protocol", "meridian-proxy", "meridian-launcher"}


def api(url):
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "meridian-catalog-builder"}
    if TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def api_paged(url):
    """Follows per_page pagination; the org is small but this keeps it correct."""
    items = []
    page = 1
    while True:
        sep = "&" if "?" in url else "?"
        chunk = api(f"{url}{sep}per_page=100&page={page}")
        if not isinstance(chunk, list) or not chunk:
            break
        items.extend(chunk)
        if len(chunk) < 100:
            break
        page += 1
    return items


def download(url):
    # Public release assets download from the CDN without auth (sending the API token to the
    # redirected object host can be rejected, so we deliberately omit it here).
    req = urllib.request.Request(url, headers={"User-Agent": "meridian-catalog-builder",
                                               "Accept": "application/octet-stream"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def read_module_json(jar_bytes):
    try:
        with zipfile.ZipFile(io.BytesIO(jar_bytes)) as z:
            with z.open("module.json") as f:
                return json.load(f)
    except Exception:
        return None


def read_manifest(assets):
    """The release's CI-generated meridian.json, or None (legacy release)."""
    if "meridian.json" not in assets:
        return None
    try:
        return json.loads(download(assets["meridian.json"]["browser_download_url"]).decode("utf-8"))
    except Exception:
        return None


def games_from_tag(tag):
    # A legacy release tag may pin game versions after '+', e.g. 2.0.0+0.5.9 or 2.0.0+0.5.9,0.6.x.
    if tag and "+" in tag:
        parts = [g.strip() for g in tag.split("+", 1)[1].split(",") if g.strip()]
        return parts or None
    return None


def load_prior_index(path):
    """Index prior version entries by asset id (assets are immutable) → reuse to skip downloads."""
    idx = {}
    try:
        with open(path, encoding="utf-8") as f:
            for module in json.load(f).get("modules", []):
                for v in module.get("versions", []):
                    if v.get("assetId") is not None:
                        idx[v["assetId"]] = v
    except Exception:
        pass
    return idx


def module_entry_from_manifest(release, asset, build, manifest):
    """A catalog version entry straight from the release's meridian.json — no downloads."""
    mj = build.get("module") or {}
    requires = mj.get("requires") or {}
    return {
        "assetId": asset["id"],
        "version": manifest.get("version") or release.get("tag_name"),
        "prerelease": bool(release.get("prerelease")),
        "jarName": asset["name"],
        "url": asset["browser_download_url"],
        "size": build.get("size", asset.get("size")),
        "sha256": build.get("sha256"),
        "moduleName": mj.get("name"),
        "moduleVersion": mj.get("version"),
        "main": mj.get("main"),
        "minProxyVersion": mj.get("minProxyVersion") or mj.get("minCoreVersion"),
        "maxProxyVersion": mj.get("maxProxyVersion") or mj.get("maxCoreVersion"),
        "dependsOn": mj.get("dependsOn"),
        "layer1": bool(build.get("games")) or bool(requires.get("packets")),
        "games": build.get("games"),
    }


def module_entry_legacy(release, asset, prior):
    """Legacy release without a manifest: download the jar to hash it + read module.json."""
    aid = asset["id"]
    reuse = prior.get(aid)
    if reuse:
        return dict(reuse)   # immutable asset → identical content, reuse hash + parsed fields
    data = download(asset["browser_download_url"])
    mj = read_module_json(data) or {}
    requires = mj.get("requires") or {}
    return {
        "assetId": aid,
        "version": release.get("tag_name"),
        "prerelease": bool(release.get("prerelease")),
        "jarName": asset["name"],
        "url": asset["browser_download_url"],
        "size": asset.get("size"),
        "sha256": hashlib.sha256(data).hexdigest(),
        "moduleName": mj.get("name"),
        "moduleVersion": mj.get("version"),
        "main": mj.get("main"),
        "minProxyVersion": mj.get("minProxyVersion") or mj.get("minCoreVersion"),
        "maxProxyVersion": mj.get("maxProxyVersion") or mj.get("maxCoreVersion"),
        "dependsOn": mj.get("dependsOn"),
        "layer1": bool(requires.get("packets")),
        "games": games_from_tag(release.get("tag_name")),
    }


def build_module(repo_name, prior):
    """Every published version of one module repo, newest release first."""
    versions = []
    for release in api_paged(f"{API}/repos/{ORG}/{repo_name}/releases"):
        if release.get("draft"):
            continue
        assets = {a["name"]: a for a in release.get("assets", [])}
        manifest = read_manifest(assets)
        if manifest and isinstance(manifest.get("builds"), list) and manifest["builds"]:
            for b in manifest["builds"]:
                asset = assets.get(b.get("asset"))
                if asset is None or not asset["name"].endswith(".jar"):
                    continue
                versions.append(module_entry_from_manifest(release, asset, b, manifest))
        else:
            for asset in release.get("assets", []):
                if not asset["name"].endswith(".jar"):
                    continue
                versions.append(module_entry_legacy(release, asset, prior))
    module_name = next((v["moduleName"] for v in versions if v.get("moduleName")), None)
    return versions, module_name


def build_end_app(repo, kind):
    """proxy / launcher: one catalog entry per released jar, described by the release's
    meridian.json `builds` array (legacy single-jar {"asset","proto","sha256"} still accepted)."""
    out = []
    for rel in api_paged(f"{API}/repos/{ORG}/{repo}/releases"):
        if rel.get("draft"):
            continue
        assets = {a["name"]: a for a in rel.get("assets", [])}
        meta = read_manifest(assets) or {}
        version = meta.get("version") or rel.get("tag_name")
        builds = meta.get("builds")
        if not (isinstance(builds, list) and builds):
            # legacy single jar: synthesize a one-element builds list
            builds = [{"asset": meta.get("asset"), "proto": meta.get("proto"), "sha256": meta.get("sha256")}]
        for b in builds:
            jar = assets.get(b.get("asset")) if b.get("asset") else None
            if jar is None:   # fall back to any jar only for a truly bare legacy release
                jar = next((a for n, a in assets.items() if n.endswith(".jar")), None)
            if jar is None:
                continue
            entry = {
                "version": version,
                "tag": rel.get("tag_name"),
                "prerelease": bool(rel.get("prerelease")),
                "jarName": jar["name"],
                "url": jar["browser_download_url"],
                "size": b.get("size", jar.get("size")),
                "sha256": b.get("sha256"),
            }
            if kind == "proxy":
                entry["proto"] = b.get("proto")   # protocol CRC → matched to the game version
            if b.get("games"):
                entry["games"] = b.get("games")
            out.append(entry)
    return out


def build_games():
    """game line → protocol CRC, read from meridian-protocol's own line/* branches: each branch's
    pom version IS the wire CRC (its build guards version == PROTOCOL_CRC in the source)."""
    games = {}
    try:
        branches = api_paged(f"{API}/repos/{ORG}/meridian-protocol/branches")
    except urllib.error.HTTPError:
        return games
    for br in branches:
        name = br.get("name", "")
        if not name.startswith("line/"):
            continue
        line = name[len("line/"):]
        try:
            pom = download(f"https://raw.githubusercontent.com/{ORG}/meridian-protocol/{name}/pom.xml").decode("utf-8")
            m = re.search(r"<version>(\d+)</version>", pom)   # CRC versions are purely numeric
            if m:
                games[line] = int(m.group(1))
        except Exception:
            pass
    return games


def main():
    prior = load_prior_index(PRIOR)
    repos = api_paged(f"{API}/orgs/{ORG}/repos?type=public")
    modules = []
    for repo in sorted(repos, key=lambda r: r["name"].lower()):
        name = repo["name"]
        if name in FRAMEWORK or repo.get("archived"):
            continue
        versions, module_name = build_module(name, prior)
        if not versions:
            continue   # repo ships no module jar → not an installable module
        modules.append({
            "repo": name,
            "name": module_name or name,
            "description": repo.get("description"),
            "htmlUrl": repo.get("html_url"),
            "layer": 1 if any(v.get("layer1") for v in versions) else 2,
            "versions": versions,
        })

    proxy = build_end_app("meridian-proxy", "proxy")
    launcher = build_end_app("meridian-launcher", "launcher")
    games = build_games()

    generated_at = os.environ.get("GENERATED_AT") or \
        datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    catalog = {
        "schema": 1,
        "generatedAt": generated_at,
        "org": ORG,
        "modules": modules,
        "proxy": {"repo": "meridian-proxy", "versions": proxy},
        "launcher": {"repo": "meridian-launcher", "versions": launcher},
        "games": games,
    }
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
        f.write("\n")
    total = sum(len(m["versions"]) for m in modules)
    print(f"Wrote {OUT}: {len(modules)} modules ({total} ver), "
          f"{len(proxy)} proxy, {len(launcher)} launcher, {len(games)} game-lines")


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as e:
        print(f"GitHub API error {e.code}: {e.reason}", file=sys.stderr)
        sys.exit(1)
