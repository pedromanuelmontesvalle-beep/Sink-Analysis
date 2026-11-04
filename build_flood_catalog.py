"""Build/refresh the root "Flood Analysis" STAC catalog and the directory
that gets served over http for it.

Scans `data_root` for every prefecture's own STAC catalog (anything matching
`*/*_stac/catalog.json`, i.e. the `{prefecture}_stac/catalog.json` layout
FINAL_SINK_PIPELINE.ipynb writes under `data/{prefecture} info all/`) and:

1. Writes a lightweight root catalog at `data_root/flood_stac/catalog.json`
   that just links to each one as a child - it does not copy or rewrite any
   prefecture's own catalog/collection/item files.

2. Maintains `data_root/_flood_serve/`, a directory containing an NTFS
   directory junction per prefecture folder (`{prefecture} info all`) plus
   one for `flood_stac` itself. `data_root` also holds a lot of unrelated
   project data (other datasets, scratch files, etc.) that has nothing to do
   with this catalog, so http-server should point at `_flood_serve` instead
   of `data_root` directly - junctions keep the exact same relative folder
   layout (so every relative href in every catalog/collection/item still
   resolves the same way) while only exposing the prefecture folders that
   are actually part of this catalog.

Because it only *links*/*junctions* rather than copying, a newly added
prefecture is picked up automatically the next time this runs (which
FINAL_SINK_PIPELINE.ipynb's STAC catalog cell does for you after writing that
prefecture's own catalog) - no manual wiring needed.

Serve `data_root/_flood_serve` over http (not `data_root` itself) so the root
catalog's relative child links, and every prefecture catalog's relative asset
hrefs, resolve from the same origin without exposing anything else in
`data_root`:
    npx http-server "<data_root>/_flood_serve" -p 8000 --cors -c-1
    SB_catalogUrl=http://localhost:8000/flood_stac/catalog.json
"""

import json
import os
import subprocess
from pathlib import Path

STAC_VERSION = "1.1.0"
SERVE_DIRNAME = "_flood_serve"


def _ensure_junction(link_path: Path, target_path: Path) -> None:
    """Create an NTFS directory junction at `link_path` pointing at
    `target_path`, if one doesn't already exist there. Junctions (unlike
    symlinks) don't require admin/developer-mode privileges on Windows."""
    if link_path.exists():
        return
    subprocess.run(
        ["cmd", "/c", "mklink", "/J", str(link_path), str(target_path)],
        check=True,
        capture_output=True,
        text=True,
    )


def build_root_catalog(data_root: Path) -> Path:
    data_root = Path(data_root)
    root_dir = data_root / "flood_stac"
    root_dir.mkdir(parents=True, exist_ok=True)
    root_path = root_dir / "catalog.json"

    links = [{"rel": "root", "href": "./catalog.json", "type": "application/json"}]
    prefecture_dirs = []

    for child_path in sorted(data_root.glob("*/*_stac/catalog.json")):
        prefecture_dir = child_path.parent.parent
        if prefecture_dir.name in (SERVE_DIRNAME, "flood_stac"):
            # Skip our own output dirs - `_flood_serve` junctions a `flood_stac`
            # entry into itself, which would otherwise match this same glob.
            continue
        child = json.loads(child_path.read_text(encoding="utf-8"))
        rel_href = Path(os.path.relpath(child_path, root_dir)).as_posix()
        links.append(
            {
                "rel": "child",
                "href": rel_href,
                "type": "application/json",
                "title": child.get("id", child_path.parent.parent.name),
            }
        )
        prefecture_dirs.append(prefecture_dir)

    catalog = {
        "type": "Catalog",
        "id": "flood-analysis",
        "stac_version": STAC_VERSION,
        "description": "Flood risk analysis (sink depth, roads, buildings) across every processed prefecture",
        "title": "Flood Analysis",
        "links": links,
    }

    root_path.write_text(json.dumps(catalog, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"wrote root catalog to {root_path}: {len(links) - 1} prefecture(s) linked")

    serve_dir = data_root / SERVE_DIRNAME
    serve_dir.mkdir(parents=True, exist_ok=True)
    _ensure_junction(serve_dir / "flood_stac", root_dir)
    for prefecture_dir in prefecture_dirs:
        _ensure_junction(serve_dir / prefecture_dir.name, prefecture_dir)
    print(f"serve directory ready at {serve_dir}")

    return root_path


if __name__ == "__main__":
    import sys

    data_root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "data"
    build_root_catalog(data_root)
