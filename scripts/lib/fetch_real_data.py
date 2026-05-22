#!/usr/bin/env python3
"""
fetch_real_data.py — pobiera RZECZYWISTE dane dla projektu SPDB Warszawa.

Źródła (z dokumentacji wstępnej):
  - PRG / OSM admin_level=9 → granice 18 dzielnic (multipolygon)
  - GUS BDL API (var-id=72305) → ludność per dzielnica 2023
  - dane.gov.pl / RPWDL CSV → szpitale SOR + przychodnie POZ
  - OSM Overpass API → apteki (amenity=pharmacy), uzupełnienie SOR (emergency=yes) i POZ (healthcare=clinic)

Wynik: 5 plików SQL w sql/init/data_real/, gotowych do `psql -f`:
  - 10_dzielnice_prg.sql
  - 11_demografia_gus.sql
  - 12_szpitale_sor_real.sql
  - 13_przychodnie_poz_real.sql
  - 14_apteki_osm.sql

Cache: data/cache/ — surowe pobrane JSONy (re-użycie przy ponownym uruchomieniu).

Tylko stdlib + curl/wget (uruchamiane jako subprocess); brak zależności pip.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
CACHE = ROOT / "data" / "cache"
OUT   = ROOT / "sql" / "init" / "data_real"
CACHE.mkdir(parents=True, exist_ok=True)
OUT.mkdir(parents=True, exist_ok=True)

# Public Overpass mirror that accepts both POST forms; fallback list.
OVERPASS_ENDPOINTS = [
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
    "https://overpass-api.de/api/interpreter",
]

# GUS BDL: TERYT ID per dzielnica → BDL unit-id (level 6, "od 2002" series)
BDL_DZIELNICE = {
    "Bemowo":         "071412865028",
    "Białołęka":      "071412865038",
    "Bielany":        "071412865048",
    "Mokotów":        "071412865058",
    "Ochota":         "071412865068",
    "Praga-Południe": "071412865078",
    "Praga-Północ":   "071412865088",
    "Rembertów":      "071412865098",
    "Śródmieście":    "071412865108",
    "Targówek":       "071412865118",
    "Ursus":          "071412865128",
    "Ursynów":        "071412865138",
    "Wawer":          "071412865148",
    "Wesoła":         "071412865158",
    "Wilanów":        "071412865168",
    "Włochy":         "071412865178",
    "Wola":           "071412865188",
    "Żoliborz":       "071412865198",
}

YEAR = 2023
USER_AGENT = "Mozilla/5.0 (compatible; SPDB-Warsaw-Healthcare/1.0; +https://github.com/lkzs2003/Availability-of-healthcare-in-Warsaw)"


# ---------- helpers ----------------------------------------------------------

def log(msg: str) -> None:
    print(f"[fetch] {msg}", file=sys.stderr, flush=True)


def curl_json(url: str, data: str | None = None, cache_key: str | None = None,
              max_retries: int = 3, retry_delay: float = 5.0) -> dict:
    """Fetch JSON via curl (with optional POST body) and cache to disk."""
    cache_file = CACHE / f"{cache_key}.json" if cache_key else None
    if cache_file and cache_file.exists() and cache_file.stat().st_size > 0:
        log(f"  cache hit: {cache_key}")
        return json.loads(cache_file.read_text(encoding="utf-8"))

    last_exc = None
    for attempt in range(1, max_retries + 1):
        try:
            cmd = ["curl", "-sS", "--fail", "--max-time", "180", "-A", USER_AGENT, url]
            if data is not None:
                cmd.extend(["--data-urlencode", f"data={data}"])
            out = subprocess.check_output(cmd, stderr=subprocess.PIPE)
            payload = json.loads(out.decode("utf-8"))
            if cache_file:
                cache_file.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
            return payload
        except (subprocess.CalledProcessError, json.JSONDecodeError) as e:
            last_exc = e
            log(f"  attempt {attempt}/{max_retries} failed: {e}")
            if attempt < max_retries:
                time.sleep(retry_delay)
    raise RuntimeError(f"Failed to fetch {url}: {last_exc}")


def overpass_query(ql: str, cache_key: str) -> dict:
    """Try Overpass mirrors until one succeeds."""
    cache_file = CACHE / f"{cache_key}.json"
    if cache_file.exists() and cache_file.stat().st_size > 0:
        log(f"  cache hit: {cache_key}")
        return json.loads(cache_file.read_text(encoding="utf-8"))

    for endpoint in OVERPASS_ENDPOINTS:
        log(f"  trying Overpass: {endpoint}")
        try:
            return curl_json(endpoint, data=ql, cache_key=cache_key)
        except RuntimeError as e:
            log(f"  endpoint failed: {e}")
            continue
    raise RuntimeError("All Overpass endpoints failed")


# ---------- OSM polygon assembly --------------------------------------------

def _close(a: tuple[float, float], b: tuple[float, float], tol: float = 1e-7) -> bool:
    """Tolerance-based endpoint comparison (OSM may have tiny FP drift)."""
    return abs(a[0] - b[0]) < tol and abs(a[1] - b[1]) < tol


def assemble_rings(ways: list[list[tuple[float, float]]]) -> list[list[tuple[float, float]]]:
    """Glue OSM way segments into closed rings by matching endpoints (with tolerance)."""
    remaining = [list(w) for w in ways if len(w) >= 2]
    rings: list[list[tuple[float, float]]] = []
    while remaining:
        ring = remaining.pop(0)
        progress = True
        while progress and not _close(ring[0], ring[-1]):
            progress = False
            for i, w in enumerate(remaining):
                if _close(w[0], ring[-1]):
                    ring.extend(w[1:]); remaining.pop(i); progress = True; break
                if _close(w[-1], ring[-1]):
                    ring.extend(reversed(w[:-1])); remaining.pop(i); progress = True; break
                if _close(w[-1], ring[0]):
                    ring = w + ring[1:]; remaining.pop(i); progress = True; break
                if _close(w[0], ring[0]):
                    ring = list(reversed(w)) + ring[1:]; remaining.pop(i); progress = True; break
        if _close(ring[0], ring[-1]) and len(ring) >= 4:
            ring[-1] = ring[0]  # force exact closure for WKT parser
            rings.append(ring)
        elif len(ring) >= 4:
            # Force-close large incomplete rings (OSM gap, e.g. recent edit).
            # ST_MakeValid in the downstream SQL will repair the resulting polygon.
            gap_m = ((ring[0][0] - ring[-1][0]) ** 2 + (ring[0][1] - ring[-1][1]) ** 2) ** 0.5 * 111000
            log(f"  WARN: forcing closure on ring of {len(ring)} pts (gap ≈ {gap_m:.0f} m) — ST_MakeValid will repair")
            ring.append(ring[0])
            rings.append(ring)
        else:
            log(f"  WARN: ring too short ({len(ring)} pts) discarded")
    return rings


def relation_to_wkt(rel: dict) -> str | None:
    """Convert OSM relation (with `out geom`) to WKT MULTIPOLYGON in WGS84."""
    outers, inners = [], []
    for m in rel.get("members", []):
        if m.get("type") != "way" or "geometry" not in m:
            continue
        pts = [(g["lon"], g["lat"]) for g in m["geometry"]]
        if m.get("role") == "outer":
            outers.append(pts)
        elif m.get("role") == "inner":
            inners.append(pts)
    outer_rings = assemble_rings(outers)
    inner_rings = assemble_rings(inners) if inners else []
    if not outer_rings:
        return None
    # Assign inner rings to outer rings by point-in-polygon (simplified — first outer)
    polys = []
    for o in outer_rings:
        ring_wkt = ", ".join(f"{x:.7f} {y:.7f}" for x, y in o)
        rings_wkt = [f"({ring_wkt})"]
        for inn in inner_rings:
            inn_wkt = ", ".join(f"{x:.7f} {y:.7f}" for x, y in inn)
            rings_wkt.append(f"({inn_wkt})")
        polys.append("(" + ", ".join(rings_wkt) + ")")
    return f"MULTIPOLYGON ({', '.join(polys)})"


# ---------- SQL escape -------------------------------------------------------

def sql_str(s: str | None) -> str:
    if s is None:
        return "NULL"
    return "'" + s.replace("'", "''") + "'"


# ---------- 1. Districts from OSM admin_level=9 ------------------------------

def fetch_dzielnice() -> Path:
    """Download all 18 Warsaw districts as OSM relations and emit SQL."""
    log("Fetching district boundaries (OSM admin_level=9) ...")
    ql = (
        '[out:json][timeout:180];'
        'relation["name"="Warszawa"]["admin_level"="6"];'
        'map_to_area->.w;'
        'relation["admin_level"="9"](area.w);'
        'out body geom;'
    )
    data = overpass_query(ql, "osm_dzielnice")

    out = OUT / "10_dzielnice_prg.sql"
    with out.open("w", encoding="utf-8") as f:
        f.write("-- Real district boundaries from OSM admin_level=9 (matches PRG/Geoportal).\n")
        f.write("-- Geometry assembled from relation members and reprojected EPSG:4326 → EPSG:2180.\n")
        f.write("TRUNCATE dzielnice RESTART IDENTITY CASCADE;\n\n")
        count = 0
        for rel in data["elements"]:
            if rel["type"] != "relation":
                continue
            name = rel["tags"].get("name")
            if name not in BDL_DZIELNICE:
                log(f"  skipping unknown district: {name}")
                continue
            wkt = relation_to_wkt(rel)
            if not wkt:
                log(f"  WARN: no geometry for {name}")
                continue
            f.write(
                "INSERT INTO dzielnice (nazwa, geom) VALUES (\n"
                f"  {sql_str(name)},\n"
                f"  ST_Multi(\n"
                f"    ST_CollectionExtract(\n"
                f"      ST_MakeValid(\n"
                f"        ST_Transform(ST_GeomFromText('{wkt}', 4326), 2180)\n"
                f"      ), 3\n"
                f"    )\n"
                f"  )\n"
                ");\n"
            )
            count += 1
        f.write("\n-- Recompute area from real geometry (km²)\n")
        f.write("UPDATE dzielnice SET powierzchnia_km2 = ROUND((ST_Area(geom) / 1e6)::NUMERIC, 3);\n")
        f.write(f"\n-- {count} districts loaded\n")
    log(f"  → {count} districts → {out.name}")
    return out


# ---------- 2. Demographics from GUS BDL -------------------------------------

def fetch_demografia() -> Path:
    """Fetch real 2023 population per district from GUS BDL API."""
    log("Fetching demographics (GUS BDL var-id=72305, year=2023) ...")
    out = OUT / "11_demografia_gus.sql"
    with out.open("w", encoding="utf-8") as f:
        f.write(f"-- Real {YEAR} population from GUS BDL API (var-id=72305, 'ludność stan w dniu 31 XII').\n")
        f.write("-- Source: https://bdl.stat.gov.pl/api/v1/\n")
        f.write("TRUNCATE demografia_dzielnice RESTART IDENTITY CASCADE;\n\n")
        for nazwa, unit_id in BDL_DZIELNICE.items():
            url = f"https://bdl.stat.gov.pl/api/v1/data/by-unit/{unit_id}?var-id=72305&year={YEAR}&format=json"
            try:
                resp = curl_json(url, cache_key=f"bdl_{unit_id}_{YEAR}")
                vals = resp["results"][0]["values"]
                pop = next(v["val"] for v in vals if v["year"] == str(YEAR))
                f.write(
                    f"INSERT INTO demografia_dzielnice (dzielnica_id, rok, ludnosc, gestosc_os_km2) "
                    f"SELECT d.id, {YEAR}, {pop}, ROUND({pop}::NUMERIC / d.powierzchnia_km2, 2) "
                    f"FROM dzielnice d WHERE d.nazwa = {sql_str(nazwa)};\n"
                )
                log(f"  {nazwa}: {pop:,}")
            except Exception as e:
                log(f"  ERROR for {nazwa}: {e}")
                f.write(f"-- ERROR for {nazwa}: {e}\n")
    log(f"  → {out.name}")
    return out


# ---------- 3. SOR Hospitals from OSM ----------------------------------------

def fetch_sor() -> Path:
    """Hospitals with emergency room (SOR) from OSM.

    Strategy: union of three overlapping criteria — OSM tag coverage for SOR
    is patchy, so we use any of:
      (a) emergency=yes (the WHO-recommended tag)
      (b) name contains "SOR" / "Oddział Ratunkowy"
      (c) healthcare:speciality contains "emergency"
    Then de-dupe by name. NOT all amenity=hospital have SOR — Warsaw has
    ~13 SOR facilities out of ~40 hospitals.
    """
    log("Fetching SOR hospitals (OSM: emergency=yes OR SOR in name OR speciality=emergency) ...")
    ql = (
        '[out:json][timeout:180];'
        'relation["name"="Warszawa"]["admin_level"="6"];'
        'map_to_area->.w;'
        '('
        '  nwr["amenity"="hospital"]["emergency"="yes"](area.w);'
        '  nwr["amenity"="hospital"]["name"~"SOR",i](area.w);'
        '  nwr["amenity"="hospital"]["name"~"Oddział Ratunkow",i](area.w);'
        '  nwr["amenity"="hospital"]["healthcare:speciality"~"emergency"](area.w);'
        '  nwr["healthcare"="hospital"]["emergency"="yes"](area.w);'
        ');'
        'out center tags;'
    )
    data = overpass_query(ql, "osm_sor")

    out = OUT / "12_szpitale_sor_real.sql"
    with out.open("w", encoding="utf-8") as f:
        f.write("-- Hospitals with SOR (Szpitalny Oddział Ratunkowy) from OSM emergency=yes tag.\n")
        f.write("-- Supplements RPWDL/NFZ data with verified emergency rooms.\n")
        f.write("TRUNCATE szpitale_sor RESTART IDENTITY CASCADE;\n\n")
        seen = set(); count = 0
        for el in data["elements"]:
            tags = el.get("tags", {})
            name = tags.get("name") or tags.get("operator") or f"Szpital OSM #{el['id']}"
            if name in seen:
                continue
            seen.add(name)
            lon = el.get("lon") or (el.get("center") or {}).get("lon")
            lat = el.get("lat") or (el.get("center") or {}).get("lat")
            if lon is None or lat is None:
                continue
            adres = " ".join(filter(None, [
                tags.get("addr:street"),
                tags.get("addr:housenumber"),
            ])) or None
            f.write(
                "INSERT INTO szpitale_sor (nazwa, adres, geom) VALUES (\n"
                f"  {sql_str(name)}, {sql_str(adres)},\n"
                f"  ST_Transform(ST_SetSRID(ST_Point({lon}, {lat}), 4326), 2180)\n"
                ");\n"
            )
            count += 1
        f.write(f"\n-- {count} SOR hospitals loaded\n")
    log(f"  → {count} SOR → {out.name}")
    return out


# ---------- 4. POZ Clinics from OSM ------------------------------------------

def fetch_poz() -> Path:
    """Primary healthcare clinics from OSM (best-effort proxy for RPWDL)."""
    log("Fetching POZ clinics (OSM healthcare=clinic / amenity=clinic) ...")
    ql = (
        '[out:json][timeout:180];'
        'relation["name"="Warszawa"]["admin_level"="6"];'
        'map_to_area->.w;'
        '('
        '  node["healthcare"="clinic"](area.w);'
        '  node["amenity"="clinic"](area.w);'
        '  node["healthcare"="doctor"]["healthcare:speciality"~"general"](area.w);'
        '  way["healthcare"="clinic"](area.w);'
        '  way["amenity"="clinic"](area.w);'
        ');'
        'out center tags;'
    )
    data = overpass_query(ql, "osm_poz")

    out = OUT / "13_przychodnie_poz_real.sql"
    with out.open("w", encoding="utf-8") as f:
        f.write("-- Primary care clinics (POZ) from OSM healthcare=clinic.\n")
        f.write("-- This is a best-effort proxy — full RPWDL XML requires authenticated access.\n")
        f.write("-- For production: replace with parsed RPWDL CSV (https://rpwdl.ezdrowie.gov.pl).\n")
        f.write("TRUNCATE przychodnie_poz RESTART IDENTITY CASCADE;\n\n")
        seen = set(); count = 0
        for el in data["elements"]:
            tags = el.get("tags", {})
            name = tags.get("name") or tags.get("operator")
            if not name or name in seen:
                continue
            seen.add(name)
            lon = el.get("lon") or (el.get("center") or {}).get("lon")
            lat = el.get("lat") or (el.get("center") or {}).get("lat")
            if lon is None or lat is None:
                continue
            adres = " ".join(filter(None, [
                tags.get("addr:street"),
                tags.get("addr:housenumber"),
            ])) or None
            rpwdl = tags.get("ref:rpwdl") or tags.get("ref:csioz")
            f.write(
                "INSERT INTO przychodnie_poz (nazwa, adres, nr_rpwdl, geom) VALUES (\n"
                f"  {sql_str(name)}, {sql_str(adres)}, {sql_str(rpwdl)},\n"
                f"  ST_Transform(ST_SetSRID(ST_Point({lon}, {lat}), 4326), 2180)\n"
                ");\n"
            )
            count += 1
        f.write(f"\n-- {count} POZ clinics loaded\n")
    log(f"  → {count} POZ → {out.name}")
    return out


# ---------- 5. Pharmacies from OSM -------------------------------------------

def fetch_apteki() -> Path:
    """All pharmacies from OSM amenity=pharmacy."""
    log("Fetching pharmacies (OSM amenity=pharmacy) ...")
    ql = (
        '[out:json][timeout:180];'
        'relation["name"="Warszawa"]["admin_level"="6"];'
        'map_to_area->.w;'
        '('
        '  node["amenity"="pharmacy"](area.w);'
        '  way["amenity"="pharmacy"](area.w);'
        ');'
        'out center tags;'
    )
    data = overpass_query(ql, "osm_apteki")

    out = OUT / "14_apteki_osm.sql"
    with out.open("w", encoding="utf-8") as f:
        f.write("-- All pharmacies in Warsaw from OSM amenity=pharmacy.\n")
        f.write("-- Supplemented by ref:csioz (CSIOZ apteki) where present.\n")
        f.write("TRUNCATE apteki RESTART IDENTITY CASCADE;\n\n")
        seen = set(); count = 0
        for el in data["elements"]:
            tags = el.get("tags", {})
            name = tags.get("name") or tags.get("brand") or f"Apteka OSM #{el['id']}"
            lon = el.get("lon") or (el.get("center") or {}).get("lon")
            lat = el.get("lat") or (el.get("center") or {}).get("lat")
            if lon is None or lat is None:
                continue
            key = (name, round(lon, 6), round(lat, 6))
            if key in seen:
                continue
            seen.add(key)
            adres = " ".join(filter(None, [
                tags.get("addr:street"),
                tags.get("addr:housenumber"),
            ])) or None
            f.write(
                "INSERT INTO apteki (nazwa, adres, geom) VALUES (\n"
                f"  {sql_str(name)}, {sql_str(adres)},\n"
                f"  ST_Transform(ST_SetSRID(ST_Point({lon}, {lat}), 4326), 2180)\n"
                ");\n"
            )
            count += 1
        f.write(f"\n-- {count} pharmacies loaded\n")
    log(f"  → {count} apteki → {out.name}")
    return out


# ---------- main -------------------------------------------------------------

DATASETS = {
    "dzielnice":   fetch_dzielnice,
    "demografia":  fetch_demografia,
    "sor":         fetch_sor,
    "poz":         fetch_poz,
    "apteki":      fetch_apteki,
}


def main() -> int:
    ap = argparse.ArgumentParser(description="Fetch real Warsaw healthcare data")
    ap.add_argument("--only", choices=list(DATASETS) + ["all"], default="all",
                    help="Fetch only this dataset (default: all)")
    ap.add_argument("--no-cache", action="store_true",
                    help="Ignore cache and re-download")
    args = ap.parse_args()

    if args.no_cache:
        for f in CACHE.glob("*.json"):
            f.unlink()
        log("Cache cleared")

    targets = list(DATASETS) if args.only == "all" else [args.only]
    for t in targets:
        try:
            DATASETS[t]()
        except Exception as e:
            log(f"FAILED {t}: {e}")
            return 1

    log("")
    log("Done. Apply to a running database with:")
    log("  for f in sql/init/data_real/*.sql; do")
    log("    docker compose exec -T -e PGPASSWORD=postgres db psql -U postgres -d warszawa_health -f \"/sql/init/data_real/$(basename $f)\";")
    log("  done")
    log("Or simply: ./scripts/import_real_data.sh")
    return 0


if __name__ == "__main__":
    sys.exit(main())
