#!/usr/bin/env python3
"""Render PNG visualizations of every scenario by querying PostGIS for GeoJSON
and drawing with matplotlib (no geopandas dependency).
"""
import json
import os
import subprocess
import sys
from pathlib import Path

import matplotlib.patches as mpatches
import matplotlib.pyplot as plt
from matplotlib.collections import PatchCollection
from matplotlib.path import Path as MPath

ROOT = Path(__file__).resolve().parent.parent.parent
OUT = ROOT / "docs" / "img"
OUT.mkdir(parents=True, exist_ok=True)

DSN = ["docker", "compose", "exec", "-T", "-e", "PGPASSWORD=postgres", "db",
       "psql", "-U", "postgres", "-d", "warszawa_health", "-At", "-F\t", "-c"]


def query(sql: str) -> list[list[str]]:
    out = subprocess.check_output(DSN + [sql], cwd=ROOT).decode("utf-8")
    return [line.split("\t") for line in out.strip().split("\n") if line]


def geojson_to_patches(geojson_str: str):
    """Convert a GeoJSON geometry to matplotlib Path objects (one per ring)."""
    if not geojson_str or geojson_str == "":
        return []
    geom = json.loads(geojson_str)

    def rings_from(coords, gtype):
        if gtype == "Polygon":
            return [coords]  # list of polygons, each is list of rings
        if gtype == "MultiPolygon":
            return coords
        return []

    if geom["type"] == "GeometryCollection":
        polys = []
        for g in geom["geometries"]:
            polys.extend(rings_from(g.get("coordinates", []), g["type"]))
        return polys
    return rings_from(geom.get("coordinates", []), geom["type"])


def draw_polygon_patches(ax, polys, **kwargs):
    """Each `poly` is a list of rings; first = outer, rest = holes."""
    for poly in polys:
        if not poly:
            continue
        outer = poly[0]
        verts = list(outer)
        codes = [MPath.MOVETO] + [MPath.LINETO] * (len(outer) - 2) + [MPath.CLOSEPOLY]
        for hole in poly[1:]:
            verts.extend(hole)
            codes.extend([MPath.MOVETO] + [MPath.LINETO] * (len(hole) - 2) + [MPath.CLOSEPOLY])
        ax.add_patch(mpatches.PathPatch(MPath(verts, codes), **kwargs))


def setup_ax(ax, title):
    ax.set_aspect("equal")
    ax.set_title(title, fontsize=12)
    ax.set_xlabel("EPSG:2180 X [m]")
    ax.set_ylabel("EPSG:2180 Y [m]")
    ax.ticklabel_format(style="plain", axis="both")
    ax.grid(alpha=0.2)


def base_districts(ax, fill="#f0f0f0", edge="#888", lw=0.5):
    rows = query("SELECT ST_AsGeoJSON(geom) FROM dzielnice;")
    for r in rows:
        for poly in geojson_to_patches(r[0]):
            draw_polygon_patches(ax, [poly], facecolor=fill, edgecolor=edge, linewidth=lw)


# ---------- S1: pustynie medyczne ----------
def render_s1():
    fig, ax = plt.subplots(figsize=(11, 9))
    setup_ax(ax, "S1 — Pustynie medyczne (obszary > 1 km od POZ)")
    base_districts(ax, fill="#e8f5e9", edge="#2e7d32", lw=0.8)
    deserts = query("""
        SELECT ST_AsGeoJSON(ST_Difference(d.geom, p.geom))
        FROM dzielnice d, mv_pokrycie_poz_1km p;
    """)
    for r in deserts:
        for poly in geojson_to_patches(r[0]):
            draw_polygon_patches(ax, [poly], facecolor="#d32f2f", edgecolor="none", alpha=0.65)
    poz = query("SELECT ST_X(geom), ST_Y(geom) FROM przychodnie_poz;")
    xs, ys = zip(*[(float(x), float(y)) for x, y in poz])
    ax.scatter(xs, ys, s=6, c="#1b5e20", marker="o", label=f"POZ (n={len(xs)})", zorder=3)
    ax.legend(handles=[
        mpatches.Patch(color="#d32f2f", alpha=0.65, label="Pustynia medyczna (>1 km)"),
        mpatches.Patch(color="#e8f5e9", ec="#2e7d32", label="Dzielnice"),
        plt.Line2D([0], [0], marker="o", color="w", markerfacecolor="#1b5e20", markersize=6,
                   label=f"POZ (n={len(xs)})"),
    ], loc="upper left", fontsize=9)
    ax.autoscale_view()
    fig.tight_layout()
    fig.savefig(OUT / "s1_pustynie_medyczne.png", dpi=130)
    plt.close(fig)
    print("  -> s1_pustynie_medyczne.png")


# ---------- S2: izochrony SOR ----------
def render_s2():
    fig, ax = plt.subplots(figsize=(11, 9))
    setup_ax(ax, "S2 — Mapowanie SOR na siec drogowa (real OSM = wymaga import_osm.sh)")
    base_districts(ax, fill="#fafafa", edge="#666", lw=0.6)
    sor = query("SELECT ST_X(geom), ST_Y(geom), nazwa FROM szpitale_sor;")
    for x, y, n in sor:
        ax.plot(float(x), float(y), marker="P", markersize=14, color="#d32f2f", markeredgecolor="white", markeredgewidth=1.5)
        ax.annotate(n[:18], (float(x), float(y)), fontsize=8, xytext=(6, 6), textcoords="offset points")
    # 8333 m buffers as proxy for 10-min isochrone in absence of real road network
    iso = query("""
        SELECT ST_AsGeoJSON(ST_Buffer(geom, 8333))
        FROM szpitale_sor;
    """)
    for r in iso:
        for poly in geojson_to_patches(r[0]):
            draw_polygon_patches(ax, [poly], facecolor="#ff9800", edgecolor="#e65100", alpha=0.30, linewidth=1.0)
    ax.legend(handles=[
        plt.Line2D([0], [0], marker="P", color="w", markerfacecolor="#d32f2f", markersize=12, label=f"SOR (n={len(sor)})"),
        mpatches.Patch(color="#ff9800", alpha=0.30, label="Strefa 10 min (8 333 m euklidesowo)"),
    ], loc="upper left", fontsize=9)
    ax.autoscale_view()
    fig.tight_layout()
    fig.savefig(OUT / "s2_izochrony_sor.png", dpi=130)
    plt.close(fig)
    print("  -> s2_izochrony_sor.png")


# ---------- S3: kandydaci na nowe POZ ----------
def render_s3():
    fig, ax = plt.subplots(figsize=(11, 9))
    setup_ax(ax, "S3 — Top 5 kandydatow na nowa POZ (centroidy najwiekszych stref Voronoi)")
    base_districts(ax, fill="#fafafa", edge="#666", lw=0.6)
    # Voronoi cells colored by area
    cells = query("""
        SELECT ST_AsGeoJSON(strefa_clip), area_m2/1e6
        FROM mv_voronoi_poz ORDER BY area_m2 DESC;
    """)
    areas = [float(r[1]) for r in cells]
    a_max = max(areas) if areas else 1
    for r, a in zip(cells, areas):
        intensity = a / a_max
        color = plt.cm.YlOrRd(intensity * 0.85 + 0.05)
        for poly in geojson_to_patches(r[0]):
            draw_polygon_patches(ax, [poly], facecolor=color, edgecolor="#444", linewidth=0.5, alpha=0.85)
    # POZ points
    poz = query("SELECT ST_X(geom), ST_Y(geom) FROM przychodnie_poz;")
    xs, ys = zip(*[(float(x), float(y)) for x, y in poz])
    ax.scatter(xs, ys, s=8, c="#1565c0", marker="o", zorder=3)
    # Top 5 kandydaci
    top = query("""
        SELECT ST_X(centroid), ST_Y(centroid), ROUND((area_m2/1e6)::NUMERIC, 2)
        FROM mv_voronoi_poz ORDER BY area_m2 DESC LIMIT 5;
    """)
    for i, (x, y, a) in enumerate(top, 1):
        ax.plot(float(x), float(y), marker="*", markersize=22, color="#1a237e", markeredgecolor="white", markeredgewidth=1.5)
        ax.annotate(f"#{i} ({a} km²)", (float(x), float(y)), fontsize=9, xytext=(8, 8),
                    textcoords="offset points", fontweight="bold")
    ax.legend(handles=[
        plt.Line2D([0], [0], marker="*", color="w", markerfacecolor="#1a237e", markersize=18, label="Top 5 kandydatow"),
        plt.Line2D([0], [0], marker="o", color="w", markerfacecolor="#1565c0", markersize=8, label=f"POZ (n={len(xs)})"),
        mpatches.Patch(color=plt.cm.YlOrRd(0.85), label="Duza strefa Voronoi = slaba dostepnosc"),
    ], loc="upper left", fontsize=9)
    ax.autoscale_view()
    fig.tight_layout()
    fig.savefig(OUT / "s3_kandydaci_nowa_poz.png", dpi=130)
    plt.close(fig)
    print("  -> s3_kandydaci_nowa_poz.png")


# ---------- S4: kwartyle dostępności aptek ----------
def render_s4():
    fig, ax = plt.subplots(figsize=(11, 9))
    setup_ax(ax, "S4 — Kwartyl dostepnosci aptek per dzielnica\n(1 = najgorszy, 4 = najlepszy; 0 = poza skala)")
    rows = query("""
        WITH wskazniki AS (
            SELECT d.id, d.nazwa, d.geom, COUNT(a.id) AS liczba_aptek,
                   dd.ludnosc::NUMERIC / NULLIF(COUNT(a.id), 0) AS mieszk
            FROM dzielnice d
            LEFT JOIN apteki a ON ST_Contains(d.geom, a.geom)
            JOIN demografia_dzielnice dd ON dd.dzielnica_id=d.id AND dd.rok=2023
            GROUP BY d.id, d.nazwa, d.geom, dd.ludnosc
        )
        SELECT nazwa,
               CASE WHEN liczba_aptek = 0 THEN 0
                    ELSE NTILE(4) OVER (PARTITION BY (liczba_aptek > 0) ORDER BY mieszk DESC)
               END AS kwartyl,
               ST_AsGeoJSON(geom),
               liczba_aptek
        FROM wskazniki;
    """)
    palette = {0: "#9e9e9e", 1: "#c62828", 2: "#ef6c00", 3: "#f9a825", 4: "#2e7d32"}
    for nazwa, k, geo, n in rows:
        c = palette[int(k)]
        for poly in geojson_to_patches(geo):
            draw_polygon_patches(ax, [poly], facecolor=c, edgecolor="#333", linewidth=0.7, alpha=0.85)
        # label center
        cx = query(f"SELECT ST_X(ST_Centroid(geom)), ST_Y(ST_Centroid(geom)) FROM dzielnice WHERE nazwa='{nazwa}';")
        if cx:
            x, y = float(cx[0][0]), float(cx[0][1])
            ax.annotate(f"{nazwa}\n({n} aptek)", (x, y), fontsize=8, ha="center", va="center",
                        color="white" if int(k) in (0, 1, 4) else "black")
    ax.legend(handles=[
        mpatches.Patch(color=palette[4], label="Kwartyl 4 (najlepsza dostepnosc)"),
        mpatches.Patch(color=palette[3], label="Kwartyl 3"),
        mpatches.Patch(color=palette[2], label="Kwartyl 2"),
        mpatches.Patch(color=palette[1], label="Kwartyl 1 (najgorsza)"),
        mpatches.Patch(color=palette[0], label="Brak aptek (poza skala)"),
    ], loc="upper left", fontsize=9)
    ax.autoscale_view()
    fig.tight_layout()
    fig.savefig(OUT / "s4_kwartyle_aptek.png", dpi=130)
    plt.close(fig)
    print("  -> s4_kwartyle_aptek.png")


# ---------- S5: najbliższe apteki KNN ----------
def render_s5():
    fig, ax = plt.subplots(figsize=(10, 9))
    setup_ax(ax, "S5 — 3 najblizsze apteki od Palacu Kultury (KNN <->)")
    base_districts(ax, fill="#fafafa", edge="#888", lw=0.5)
    # All pharmacies
    apt = query("SELECT ST_X(geom), ST_Y(geom) FROM apteki;")
    xs, ys = zip(*[(float(x), float(y)) for x, y in apt])
    ax.scatter(xs, ys, s=8, c="#90caf9", alpha=0.7, marker="o", label=f"Wszystkie apteki (n={len(xs)})")
    # Reference point
    pkin = query("SELECT ST_X(ST_Transform(ST_SetSRID(ST_Point(21.0062,52.2319),4326),2180)), ST_Y(ST_Transform(ST_SetSRID(ST_Point(21.0062,52.2319),4326),2180));")
    px, py = float(pkin[0][0]), float(pkin[0][1])
    # Top 3 KNN
    knn = query("""
        WITH p AS (SELECT ST_Transform(ST_SetSRID(ST_Point(21.0062,52.2319),4326),2180) AS g)
        SELECT a.nazwa, ST_X(a.geom), ST_Y(a.geom),
               ROUND(ST_Distance(a.geom,p.g)::NUMERIC,0)
        FROM apteki a, p ORDER BY a.geom <-> p.g LIMIT 3;
    """)
    for i, row in enumerate(knn, 1):
        nazwa, x, y, d = row
        x, y = float(x), float(y)
        ax.plot([px, x], [py, y], color="#1976d2", linewidth=2.2, linestyle="--")
        ax.plot(x, y, marker="o", markersize=14, color="#d32f2f", markeredgecolor="white", markeredgewidth=2)
        ax.annotate(f"#{i} {nazwa}\n{d} m", (x, y), fontsize=9, xytext=(10, 10), textcoords="offset points",
                    bbox=dict(boxstyle="round,pad=0.3", fc="white", ec="#d32f2f"))
    ax.plot(px, py, marker="*", markersize=24, color="#1a237e", markeredgecolor="white", markeredgewidth=2)
    ax.annotate("Palac Kultury i Nauki", (px, py), fontsize=10, xytext=(12, -16), textcoords="offset points",
                fontweight="bold", color="#1a237e")
    # Zoom on Śródmieście area
    ax.set_xlim(px - 6000, px + 6000)
    ax.set_ylim(py - 4500, py + 4500)
    ax.legend(loc="upper left", fontsize=9)
    fig.tight_layout()
    fig.savefig(OUT / "s5_najblizsze_apteki.png", dpi=130)
    plt.close(fig)
    print("  -> s5_najblizsze_apteki.png")


# ---------- S6: liczba placówek per dzielnica ----------
def render_s6():
    fig, ax = plt.subplots(figsize=(11, 9))
    setup_ax(ax, "S6 — Liczba aptek per dzielnica + lokalizacje POZ i SOR")
    rows = query("""
        SELECT d.nazwa, ST_AsGeoJSON(d.geom),
               (SELECT COUNT(*) FROM apteki a WHERE ST_Contains(d.geom, a.geom)) AS aptek
        FROM dzielnice d;
    """)
    counts = [int(r[2]) for r in rows]
    cmin, cmax = min(counts), max(counts)
    for nazwa, geo, n in rows:
        n = int(n)
        intensity = (n - cmin) / max(cmax - cmin, 1)
        color = plt.cm.Blues(0.2 + intensity * 0.7)
        for poly in geojson_to_patches(geo):
            draw_polygon_patches(ax, [poly], facecolor=color, edgecolor="#333", linewidth=0.6, alpha=0.9)
        cx = query(f"SELECT ST_X(ST_Centroid(geom)), ST_Y(ST_Centroid(geom)) FROM dzielnice WHERE nazwa='{nazwa}';")
        if cx:
            x, y = float(cx[0][0]), float(cx[0][1])
            ax.annotate(f"{nazwa}\n{n}", (x, y), fontsize=7, ha="center", va="center", color="black")
    poz = query("SELECT ST_X(geom), ST_Y(geom) FROM przychodnie_poz;")
    sor = query("SELECT ST_X(geom), ST_Y(geom) FROM szpitale_sor;")
    if poz:
        xs, ys = zip(*[(float(x), float(y)) for x, y in poz])
        ax.scatter(xs, ys, s=6, c="#388e3c", marker="o", label=f"POZ (n={len(xs)})", alpha=0.6, zorder=2)
    if sor:
        xs, ys = zip(*[(float(x), float(y)) for x, y in sor])
        ax.scatter(xs, ys, s=140, c="#d32f2f", marker="P", edgecolors="white", linewidths=1.5,
                   label=f"SOR (n={len(xs)})", zorder=3)
    sm = plt.cm.ScalarMappable(cmap=plt.cm.Blues, norm=plt.Normalize(vmin=cmin, vmax=cmax))
    sm.set_array([])
    cbar = plt.colorbar(sm, ax=ax, shrink=0.6, pad=0.02)
    cbar.set_label("Liczba aptek", rotation=270, labelpad=15)
    ax.legend(loc="upper left", fontsize=9)
    ax.autoscale_view()
    fig.tight_layout()
    fig.savefig(OUT / "s6_placowki_per_dzielnica.png", dpi=130)
    plt.close(fig)
    print("  -> s6_placowki_per_dzielnica.png")


# ---------- Overview: all data ----------
def render_overview():
    fig, ax = plt.subplots(figsize=(12, 10))
    setup_ax(ax, "Przeglad danych projektu — 18 dzielnic, POZ (n=231), SOR (n=4), apteki (n=586)")
    base_districts(ax, fill="#fafafa", edge="#555", lw=0.7)
    apt = query("SELECT ST_X(geom), ST_Y(geom) FROM apteki;")
    poz = query("SELECT ST_X(geom), ST_Y(geom) FROM przychodnie_poz;")
    sor = query("SELECT ST_X(geom), ST_Y(geom) FROM szpitale_sor;")
    for rows, c, m, s, lbl in [
        (apt, "#1565c0", "o", 6, f"Apteki (n={len(apt)})"),
        (poz, "#388e3c", "s", 10, f"POZ (n={len(poz)})"),
        (sor, "#d32f2f", "P", 200, f"SOR (n={len(sor)})"),
    ]:
        if rows:
            xs, ys = zip(*[(float(x), float(y)) for x, y in rows])
            ax.scatter(xs, ys, s=s, c=c, marker=m, edgecolors="white", linewidths=0.5, label=lbl, alpha=0.85)
    ax.legend(loc="upper left", fontsize=10)
    ax.autoscale_view()
    fig.tight_layout()
    fig.savefig(OUT / "overview.png", dpi=130)
    plt.close(fig)
    print("  -> overview.png")


# ---------- main ----------
if __name__ == "__main__":
    print("Rendering visualizations -> docs/img/")
    render_overview()
    render_s1()
    render_s2()
    render_s3()
    render_s4()
    render_s5()
    render_s6()
    print("\nDone.")
