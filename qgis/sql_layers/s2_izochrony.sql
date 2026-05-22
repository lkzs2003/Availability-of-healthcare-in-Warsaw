-- QGIS layer for S2 — izochrony 5/10/15 min dla wszystkich SOR
-- Geometry column: geom, SRID: 2180, Geometry type: Geometry (Polygon/Point mix
-- — z syntetycznym grafem część stref kolapsuje do punktu; z OSM-em wszystkie poligony)
-- Style suggestion: Graduated by `strefa`, palette RdYlGn reversed
WITH hospital_vertices AS (
    SELECT DISTINCT ON (s.id) s.id AS szpital_id, s.nazwa, v.id AS vertex_id
    FROM szpitale_sor s
    CROSS JOIN LATERAL (
        SELECT id FROM drogi_vertices ORDER BY geom <-> s.geom LIMIT 1
    ) v
    ORDER BY s.id
),
reachable AS (
    SELECT hv.szpital_id, hv.nazwa, pgd.node, pgd.agg_cost,
           CASE
               WHEN pgd.agg_cost <= 4166  THEN '5min'
               WHEN pgd.agg_cost <= 8333  THEN '10min'
               WHEN pgd.agg_cost <= 12500 THEN '15min'
           END AS strefa
    FROM hospital_vertices hv,
         pgr_drivingDistance(
             'SELECT id, source, target, cost, reverse_cost FROM drogi_topo',
             ARRAY(SELECT vertex_id FROM hospital_vertices)::BIGINT[],
             12500, true
         ) pgd
    WHERE pgd.start_vid = hv.vertex_id
)
SELECT row_number() OVER () AS id,
       szpital_id, nazwa, strefa,
       ST_ConcaveHull(ST_Collect(v.geom), 0.85) AS geom  -- typ ogólny Geometry
FROM reachable r
JOIN drogi_vertices v ON v.id = r.node
WHERE strefa IS NOT NULL
GROUP BY szpital_id, nazwa, strefa
HAVING COUNT(*) >= 3  -- ≥3 wierzchołki → ConcaveHull zwraca polygon, nie point/line
ORDER BY szpital_id, strefa;
