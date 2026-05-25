#!/usr/bin/env python3
"""Render PNG visualizations using QGIS PyQGIS API (headless).

Uruchomienie:
    /Applications/QGIS-final-4_0_2.app/Contents/MacOS/QGIS-final-4_0_2 \
        --nologo --code scripts/lib/render_qgis.py

Skrypt:
  1. Tworzy QgsApplication w trybie headless
  2. Łączy się z PostGIS (warszawa_health / postgres / postgres)
  3. Dla każdego scenariusza (S1..S6):
     - tworzy QgsVectorLayer ze szablonu SQL z qgis/sql_layers/
     - aplikuje styl (kolory, transparencja, etykiety)
     - dodaje warstwy bazowe (dzielnice, drogi)
     - renderuje do PNG z legendą i tytułem
  4. Zapisuje do docs/img/qgis/sN_*.png
"""
import os
import sys
from pathlib import Path
from qgis.core import (
    Qgis,
    QgsApplication, QgsProject, QgsVectorLayer, QgsDataSourceUri,
    QgsMapSettings, QgsRectangle, QgsCoordinateReferenceSystem,
    QgsMapRendererCustomPainterJob, QgsSymbol, QgsRendererCategory,
    QgsCategorizedSymbolRenderer, QgsGraduatedSymbolRenderer,
    QgsFillSymbol, QgsLineSymbol, QgsMarkerSymbol, QgsSingleSymbolRenderer,
)
from qgis.PyQt.QtCore import QSize, QSizeF, Qt
from qgis.PyQt.QtGui import QImage, QPainter, QColor, QFont

ROOT = Path("/Users/loczeq2203/Documents/Availability-of-healthcare-in-Warsaw")
OUT = ROOT / "docs" / "img" / "qgis"
OUT.mkdir(parents=True, exist_ok=True)

# ---- bbox Warszawy (EPSG:2180) ----
BBOX = QgsRectangle(630000, 490000, 680000, 525000)
SIZE = QSize(1600, 1200)
CRS = QgsCoordinateReferenceSystem("EPSG:2180")

# ---- QgsApplication ----
# Skrypt jest uruchamiany przez `QGIS --code` -> instancja QgsApplication
# już istnieje i jest zainicjalizowana. Init/exit są zabronione w tym trybie
# (sprawdza to QGIS 4.0+). Korzystamy z aktualnej instancji.
assert QgsApplication.instance() is not None, "QGIS app not initialized"


def pg_uri(table_or_sql: str, geom_col: str = "geom",
           key: str = "id", srid: int = 2180) -> QgsDataSourceUri:
    uri = QgsDataSourceUri()
    uri.setConnection("localhost", "5432", "warszawa_health",
                      "postgres", "postgres")
    if " " in table_or_sql.strip():  # to jest SQL
        uri.setDataSource("", "(" + table_or_sql + ")", geom_col, "", key)
        uri.setSrid(str(srid))
    else:
        uri.setDataSource("public", table_or_sql, geom_col, "", key)
    return uri


def load_postgis(name: str, query_or_table: str, geom_col="geom",
                 key="id") -> QgsVectorLayer:
    uri = pg_uri(query_or_table, geom_col, key)
    layer = QgsVectorLayer(uri.uri(False), name, "postgres")
    if not layer.isValid():
        print(f"  !! WARSTWA NIEWAŻNA: {name} -> {layer.error().message()}")
        return None
    return layer


def style_single(layer: QgsVectorLayer, color: str, alpha: float = 1.0,
                 outline: str = "#333", outline_w: float = 0.3,
                 marker_size: float = 3.0):
    if layer is None:
        return
    gtype = layer.geometryType()
    if gtype == 2:  # polygon
        sym = QgsFillSymbol.createSimple({
            "color": color, "outline_color": outline,
            "outline_width": str(outline_w), "alpha": str(alpha)})
    elif gtype == 1:  # line
        sym = QgsLineSymbol.createSimple({
            "color": color, "width": str(outline_w)})
    else:  # point
        sym = QgsMarkerSymbol.createSimple({
            "color": color, "size": str(marker_size),
            "outline_color": outline, "outline_width": "0.2"})
    layer.setRenderer(QgsSingleSymbolRenderer(sym))


def render_layout(layers: list, title: str, output_png: str, subtitle: str = ""):
    """Renderuje mapę QGIS bezpośrednio do PNG (QgsMapRendererCustomPainterJob)
    z ozdobnikami (tytuł, legenda, skala) rysowanymi przez QPainter."""
    from qgis.PyQt.QtCore import QRectF, Qt
    from qgis.PyQt.QtGui import QPen, QBrush
    layers = [l for l in layers if l is not None]

    # ----- Wymiary obrazu (16:10 landscape) -----
    W, H = 1800, 1200
    MAP_LEFT, MAP_TOP = 30, 110            # marginesy mapy
    MAP_RIGHT, MAP_BOTTOM = 320, 90        # miejsce na legendę / skalę
    map_w, map_h = W - MAP_LEFT - MAP_RIGHT, H - MAP_TOP - MAP_BOTTOM

    # ----- Konfiguracja MapSettings -----
    ms = QgsMapSettings()
    ms.setLayers(layers)
    ms.setBackgroundColor(QColor(248, 248, 248))
    ms.setDestinationCrs(CRS)
    # Wyliczamy bbox dynamicznie z istniejących warstw poligonowych
    # (dzielnice są zawsze wymiarem referencyjnym), aby zrzut realnie
    # pokrywał Warszawę — hardkodowany BBOX może być przestarzały po
    # zmianach geometrii w migracji.
    bbox = None
    for l in layers:
        if l and l.geometryType() == 2:  # polygon
            ext = l.extent()
            if not ext.isEmpty():
                bbox = QgsRectangle(ext) if bbox is None else bbox
                if bbox is not None:
                    bbox.combineExtentWith(ext)
    if bbox is None or bbox.isEmpty():
        bbox = QgsRectangle(BBOX)   # fallback
    # Margines 5 % wokół danych
    margin_x = bbox.width() * 0.05
    margin_y = bbox.height() * 0.05
    bbox = QgsRectangle(bbox.xMinimum() - margin_x, bbox.yMinimum() - margin_y,
                        bbox.xMaximum() + margin_x, bbox.yMaximum() + margin_y)
    bbox_ratio = bbox.width() / bbox.height()
    target_ratio = map_w / map_h
    if target_ratio > bbox_ratio:                # potrzebne szersze bbox
        new_w = bbox.height() * target_ratio
        dx = (new_w - bbox.width()) / 2.0
        bbox = QgsRectangle(bbox.xMinimum() - dx, bbox.yMinimum(),
                            bbox.xMaximum() + dx, bbox.yMaximum())
    else:                                         # wyższe bbox
        new_h = bbox.width() / target_ratio
        dy = (new_h - bbox.height()) / 2.0
        bbox = QgsRectangle(bbox.xMinimum(), bbox.yMinimum() - dy,
                            bbox.xMaximum(), bbox.yMaximum() + dy)
    ms.setExtent(bbox)
    ms.setOutputSize(QSize(map_w, map_h))
    ms.setOutputDpi(150)

    # ----- Bazowy obraz strony -----
    img = QImage(W, H, QImage.Format.Format_ARGB32_Premultiplied)
    img.fill(QColor("white"))
    painter = QPainter(img)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)

    # ----- Renderowanie mapy do podobrazu -----
    map_img = QImage(map_w, map_h, QImage.Format.Format_ARGB32_Premultiplied)
    map_img.fill(QColor(248, 248, 248))
    map_painter = QPainter(map_img)
    map_painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)
    job = QgsMapRendererCustomPainterJob(ms, map_painter)
    job.start()
    job.waitForFinished()
    map_painter.end()
    painter.drawImage(MAP_LEFT, MAP_TOP, map_img)
    # Ramka mapy
    painter.setPen(QPen(QColor("#444"), 2))
    painter.setBrush(QBrush(Qt.BrushStyle.NoBrush))
    painter.drawRect(MAP_LEFT, MAP_TOP, map_w, map_h)

    # ----- Tytuł + podtytuł -----
    painter.setPen(QColor("#111"))
    painter.setFont(QFont("Helvetica", 24, QFont.Weight.Bold))
    painter.drawText(MAP_LEFT, 50, title)
    if subtitle:
        painter.setFont(QFont("Helvetica", 13))
        painter.setPen(QColor("#555"))
        painter.drawText(MAP_LEFT, 85, subtitle)

    # ----- Legenda (po prawej) -----
    LEG_X = MAP_LEFT + map_w + 30
    LEG_Y = MAP_TOP + 10
    painter.setPen(QColor("#111"))
    painter.setFont(QFont("Helvetica", 14, QFont.Weight.Bold))
    painter.drawText(LEG_X, LEG_Y, "Legenda")
    painter.setFont(QFont("Helvetica", 11))
    y = LEG_Y + 30
    for l in layers:
        # Próbka kolorystyczna z renderera (uproszczenie: pobierz pierwszy symbol)
        try:
            sym = l.renderer().symbol() if hasattr(l.renderer(), "symbol") else None
            color = QColor(sym.color()) if sym else QColor("#777")
        except Exception:
            color = QColor("#777")
        gtype = l.geometryType()
        painter.setBrush(QBrush(color))
        painter.setPen(QPen(QColor("#333"), 1))
        if gtype == 2:                            # polygon
            painter.drawRect(LEG_X, y - 12, 24, 14)
        elif gtype == 1:                          # line
            painter.drawLine(LEG_X, y - 5, LEG_X + 24, y - 5)
        else:                                     # point
            painter.drawEllipse(LEG_X + 6, y - 12, 12, 12)
        painter.setPen(QColor("#222"))
        painter.drawText(LEG_X + 36, y, l.name())
        y += 26

    # ----- Skala (lewy dolny róg) -----
    SC_X = MAP_LEFT + 10
    SC_Y = MAP_TOP + map_h + 35
    scale_m_per_px = bbox.width() / map_w
    scale_target_m = 5000                          # 5 km
    scale_px = int(scale_target_m / scale_m_per_px)
    painter.setPen(QPen(QColor("#111"), 2))
    painter.drawLine(SC_X, SC_Y, SC_X + scale_px, SC_Y)
    painter.drawLine(SC_X, SC_Y - 6, SC_X, SC_Y + 6)
    painter.drawLine(SC_X + scale_px, SC_Y - 6, SC_X + scale_px, SC_Y + 6)
    painter.drawLine(SC_X + scale_px // 2, SC_Y - 4,
                     SC_X + scale_px // 2, SC_Y + 4)
    painter.setFont(QFont("Helvetica", 10))
    painter.drawText(SC_X - 2, SC_Y + 22, "0")
    painter.drawText(SC_X + scale_px // 2 - 12, SC_Y + 22, "2.5 km")
    painter.drawText(SC_X + scale_px - 20, SC_Y + 22, "5 km")

    # ----- Strzałka północy (prawy górny róg mapy) -----
    N_X = MAP_LEFT + map_w - 40
    N_Y = MAP_TOP + 30
    painter.setPen(QPen(QColor("#111"), 2))
    painter.drawLine(N_X, N_Y + 30, N_X, N_Y)        # trzon
    painter.drawLine(N_X, N_Y, N_X - 8, N_Y + 10)    # lewa pióro
    painter.drawLine(N_X, N_Y, N_X + 8, N_Y + 10)    # prawa pióro
    painter.setFont(QFont("Helvetica", 14, QFont.Weight.Bold))
    painter.drawText(N_X - 8, N_Y - 6, "N")

    # ----- Stopka -----
    painter.setFont(QFont("Helvetica", 9))
    painter.setPen(QColor("#666"))
    painter.drawText(MAP_LEFT, H - 25,
                     f"CRS: EPSG:2180 (PL-1992)  ·  "
                     f"Źródło: PostGIS warszawa_health  ·  "
                     f"Renderowane przez QGIS {Qgis.QGIS_VERSION.split('-')[0]}")

    painter.end()
    if img.save(str(output_png), "PNG"):
        print(f"  -> {output_png}")
    else:
        print(f"  !! Nie udało się zapisać: {output_png}")


def main():
    print(f"Rendering QGIS visualizations -> {OUT}/")

    # ====================  Warstwy bazowe ====================
    dzielnice = load_postgis("Dzielnice (granice)", "dzielnice")
    drogi = load_postgis("Sieć drogowa", "drogi_topo")
    poz = load_postgis("Przychodnie POZ", "przychodnie_poz")
    sor = load_postgis("Szpitale SOR", "szpitale_sor")
    apteki = load_postgis("Apteki", "apteki")

    style_single(dzielnice, "#ffffff", 0.0, "#444", 0.6)
    style_single(drogi, "#bbbbbb", outline_w=0.3)
    style_single(poz, "#2ca02c", marker_size=2.5)
    style_single(sor, "#d62728", marker_size=4.5)
    style_single(apteki, "#1f77b4", marker_size=2.0)

    # ====================  OVERVIEW ====================
    render_layout(
        [apteki, poz, sor, dzielnice],
        title="Warszawa — placówki zdrowotne",
        subtitle="18 dzielnic · 582 apteki · 231 POZ · 14 SOR  (stan po V1.1+V1.2)",
        output_png=str(OUT / "overview_qgis.png"))

    # ====================  S1 — Pustynie medyczne ====================
    s1_sql = """SELECT 1 AS id,
                       ST_Difference(
                         (SELECT ST_Union(geom) FROM dzielnice),
                         (SELECT geom FROM mv_pokrycie_poz_1km)
                       ) AS geom"""
    pust = load_postgis("Pustynie medyczne (>1 km od POZ)", s1_sql, key="id")
    if pust:
        style_single(pust, "#d62728", 0.5, "#a02525", 0.4)
    render_layout(
        [pust, poz, dzielnice] if pust else [poz, dzielnice],
        title="S1 — Pustynie medyczne",
        subtitle="Obszary >1 km od najbliższej POZ  ·  ST_Buffer + ST_Union + ST_Difference",
        output_png=str(OUT / "s1_qgis.png"))

    # ====================  S2 — Izochrony SOR ====================
    # Buffer 1 km / 2 km / 3 km wokół SOR (proxy izochron na seed grid)
    s2_sql = """SELECT id, nazwa,
                 ST_Buffer(geom, 3000) AS geom
                 FROM szpitale_sor"""
    iz3 = load_postgis("Buf 3 km (~3.6 min)", s2_sql, key="id")
    s2b = """SELECT id, nazwa, ST_Buffer(geom, 2000) AS geom FROM szpitale_sor"""
    iz2 = load_postgis("Buf 2 km (~2.4 min)", s2b, key="id")
    s2a = """SELECT id, nazwa, ST_Buffer(geom, 1000) AS geom FROM szpitale_sor"""
    iz1 = load_postgis("Buf 1 km (~1.2 min)", s2a, key="id")
    for l, c, a in [(iz3, "#fee08b", 0.45), (iz2, "#fc8d59", 0.55),
                    (iz1, "#d73027", 0.65)]:
        if l:
            style_single(l, c, a, "#444", 0.2)
    render_layout(
        [iz3, iz2, iz1, sor, dzielnice],
        title="S2 — Dostępność SOR (bufory 1/2/3 km)",
        subtitle="Strefy dojazdu wokół 14 SOR  ·  pgr_drivingDistance + ST_ConcaveHull (na realnym OSM)",
        output_png=str(OUT / "s2_qgis.png"))

    # ====================  S3 — Voronoi POZ + kandydaci ====================
    voronoi = load_postgis("Voronoi POZ",
                            "SELECT cell_id AS id, strefa_clip AS geom, area_m2 "
                            "FROM mv_voronoi_poz",
                            key="id")
    if voronoi:
        style_single(voronoi, "#cccccc", 0.0, "#555", 0.3)
    # Top-5 kandydatów
    top5 = load_postgis("Top-5 kandydatów (centroidy)",
        "SELECT cell_id AS id, centroid AS geom "
        "FROM mv_voronoi_poz ORDER BY area_m2 DESC LIMIT 5",
        geom_col="geom", key="id")
    if top5:
        style_single(top5, "#ff7f0e", 1.0, "#000", 0.4, marker_size=6.0)
    render_layout(
        [voronoi, top5, poz, dzielnice] if voronoi else [top5, poz, dzielnice],
        title="S3 — Lokalizacja nowej POZ (Voronoi + Top-5)",
        subtitle="Komórki Voronoia POZ + centroidy 5 największych stref = kandydaci",
        output_png=str(OUT / "s3_qgis.png"))

    # ====================  S4 — Kwartyle aptek ====================
    s4_sql = """SELECT d.id, d.nazwa, d.geom,
                       CASE WHEN COUNT(a.id) > 0 THEN
                         NTILE(4) OVER (ORDER BY dem.ludnosc::numeric / NULLIF(COUNT(a.id),0))
                       ELSE 0 END AS kwartyl
                  FROM dzielnice d
                  LEFT JOIN apteki a ON a.dzielnica = d.nazwa
                  JOIN demografia_dzielnice dem ON dem.dzielnica_id=d.id AND dem.rok=2023
                 GROUP BY d.id, d.nazwa, d.geom, dem.ludnosc"""
    s4 = load_postgis("Kwartyle aptek/mieszkańców", s4_sql, key="id")
    if s4:
        cats = []
        colors = {0: "#cccccc", 1: "#d73027", 2: "#fc8d59",
                  3: "#fee08b", 4: "#1a9850"}
        labels = {0: "Q0 (0 aptek)", 1: "Q1 — najgorzej",
                  2: "Q2", 3: "Q3", 4: "Q4 — najlepiej"}
        for k, c in colors.items():
            sym = QgsFillSymbol.createSimple({"color": c, "outline_color": "#333",
                                              "outline_width": "0.4"})
            cats.append(QgsRendererCategory(k, sym, labels[k]))
        s4.setRenderer(QgsCategorizedSymbolRenderer("kwartyl", cats))
    render_layout(
        [s4, apteki] if s4 else [apteki, dzielnice],
        title="S4 — Kwartyle dostępności aptek per dzielnica",
        subtitle="NTILE(4) wg mieszkańcy/apteka  ·  Q4 = najlepsza, Q1 = najgorsza",
        output_png=str(OUT / "s4_qgis.png"))

    # ====================  S5 — Najbliższe apteki (KNN) ====================
    s5_pt = load_postgis("Punkt referencyjny",
        "SELECT 1 AS id, ST_Transform(ST_SetSRID(ST_Point(21.0067,52.2319),4326),2180) AS geom",
        key="id")
    s5_near = load_postgis("3 najbliższe apteki",
        "SELECT a.id, a.nazwa, a.geom FROM apteki a "
        "ORDER BY a.geom <-> ST_Transform(ST_SetSRID(ST_Point(21.0067,52.2319),4326),2180) "
        "LIMIT 3", key="id")
    if s5_pt:
        style_single(s5_pt, "#d62728", marker_size=8.0)
    if s5_near:
        style_single(s5_near, "#2ca02c", marker_size=5.0)
    render_layout(
        [s5_near, s5_pt, apteki, dzielnice],
        title="S5 — Najbliższe apteki (KNN <->)",
        subtitle="Pałac Kultury (czerwony) + 3 najbliższe apteki (zielone) z idx_apteki_geom (GiST)",
        output_png=str(OUT / "s5_qgis.png"))

    # ====================  S6 — placówki per dzielnica ====================
    s6_sql = """SELECT d.id, d.nazwa, d.geom,
                       (SELECT COUNT(*) FROM przychodnie_poz p WHERE p.dzielnica=d.nazwa) +
                       (SELECT COUNT(*) FROM apteki a WHERE a.dzielnica=d.nazwa) +
                       (SELECT COUNT(*) FROM szpitale_sor s WHERE s.dzielnica=d.nazwa) AS total
                  FROM dzielnice d"""
    s6 = load_postgis("Łączna liczba placówek per dzielnica", s6_sql, key="id")
    if s6:
        from qgis.core import QgsClassificationJenks, QgsGradientColorRamp
        ramp = QgsGradientColorRamp(QColor("#fff5eb"), QColor("#7f2704"))
        renderer = QgsGraduatedSymbolRenderer.createRenderer(
            s6, "total", 5, QgsGraduatedSymbolRenderer.Jenks,
            QgsFillSymbol.createSimple({"outline_color": "#333",
                                        "outline_width": "0.4"}), ramp)
        s6.setRenderer(renderer)
    render_layout(
        [s6, apteki, poz, sor] if s6 else [apteki, poz, sor, dzielnice],
        title="S6 — Łączna liczba placówek per dzielnica",
        subtitle="Graduated symbology (Jenks, 5 klas)  ·  Wola/Mokotów najbardziej obsługiwane",
        output_png=str(OUT / "s6_qgis.png"))

    print("\nZakończono — sprawdź:", OUT)
    # QGIS 4.0+ — w trybie --code exitQgis() jest zabronione (zarządza tym sama aplikacja)


if __name__ == "__main__":
    main()
