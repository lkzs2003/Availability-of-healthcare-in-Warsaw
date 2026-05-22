-- QGIS layer for S1 — mapa pustyń medycznych (>1 km od POZ)
-- Load via: Layer → Add Layer → Add/Edit Virtual Layer → Query
-- Geometry column: geom, SRID: 2180, Geometry type: Polygon
SELECT 1 AS id,
       ST_Difference(m.g, p.geom) AS geom
FROM mv_pokrycie_poz_1km p,
     (SELECT ST_Union(geom) AS g FROM dzielnice) m;
