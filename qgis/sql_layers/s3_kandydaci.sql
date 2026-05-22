-- QGIS layer for S3 — Top 5 kandydatów na nową przychodnię POZ
-- Geometry column: kandydat, SRID: 2180, Geometry type: Point
SELECT row_number() OVER (ORDER BY area_m2 DESC) AS id,
       ROUND((area_m2 / 1e6)::NUMERIC, 3) AS pow_strefy_km2,
       centroid AS kandydat
FROM mv_voronoi_poz
ORDER BY area_m2 DESC
LIMIT 5;
