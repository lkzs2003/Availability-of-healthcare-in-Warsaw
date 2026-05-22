-- QGIS layer for S5 — 3 najbliższe apteki od Pałacu Kultury
-- Geometry column: geom, SRID: 2180, Geometry type: Point
-- Style suggestion: Categorized symbol, color by rank (1=red, 2=orange, 3=yellow)
WITH p AS (
    SELECT ST_Transform(ST_SetSRID(ST_Point(21.0062, 52.2319), 4326), 2180) AS geom
)
SELECT row_number() OVER (ORDER BY a.geom <-> p.geom) AS rank_nr,
       a.id, a.nazwa, a.adres,
       ROUND(ST_Distance(a.geom, p.geom)::NUMERIC, 0) AS odl_m,
       a.geom
FROM apteki a, p
ORDER BY a.geom <-> p.geom
LIMIT 3;
