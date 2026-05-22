-- ============================================================
-- Materialised views — eliminate repeated heavy CTEs in S1, S2, S3.
-- Refresh after seed or after any change to przychodnie_poz, dzielnice,
-- szpitale_sor, drogi_topo with:
--   REFRESH MATERIALIZED VIEW <view_name>;
-- ============================================================


-- ---- mv_pokrycie_poz_1km --------------------------------------------------
-- Single-row MV: union of 1 km buffers around every POZ clinic.
-- Used by S1 (medical deserts) to avoid recomputing ST_Union(ST_Buffer(...))
-- inside four separate CTEs.
DROP MATERIALIZED VIEW IF EXISTS mv_pokrycie_poz_1km CASCADE;
CREATE MATERIALIZED VIEW mv_pokrycie_poz_1km AS
SELECT ST_Union(ST_Buffer(geom, 1000)) AS geom
FROM przychodnie_poz;

CREATE INDEX idx_mv_pokrycie_poz_1km_geom
    ON mv_pokrycie_poz_1km USING GiST (geom);


-- ---- mv_voronoi_poz -------------------------------------------------------
-- Voronoi cells generated from POZ centroids, clipped to the union of all
-- districts. Used by S3 (new clinic location) to avoid repeating the
-- pts/envelope/voronoi/miasto/voronoi_clip pipeline five times.
DROP MATERIALIZED VIEW IF EXISTS mv_voronoi_poz CASCADE;
CREATE MATERIALIZED VIEW mv_voronoi_poz AS
WITH pts AS (
    SELECT ST_Collect(geom) AS geom FROM przychodnie_poz
),
envelope AS (
    SELECT ST_Expand(ST_Envelope(geom), 5000) AS g FROM pts
),
voronoi AS (
    SELECT (ST_Dump(ST_VoronoiPolygons(pts.geom, 0, envelope.g))).geom AS strefa
    FROM pts, envelope
),
miasto AS (
    SELECT ST_Union(geom) AS g FROM dzielnice
)
SELECT row_number() OVER ()                                AS cell_id,
       ST_Intersection(v.strefa, m.g)                      AS strefa_clip,
       ST_Centroid(ST_Intersection(v.strefa, m.g))         AS centroid,
       ST_Area(ST_Intersection(v.strefa, m.g))             AS area_m2
FROM voronoi v, miasto m
WHERE ST_Intersects(v.strefa, m.g);

-- UNIQUE on cell_id enables REFRESH MATERIALIZED VIEW CONCURRENTLY
CREATE UNIQUE INDEX idx_mv_voronoi_poz_cell
    ON mv_voronoi_poz (cell_id);
CREATE INDEX idx_mv_voronoi_poz_geom
    ON mv_voronoi_poz USING GiST (strefa_clip);
CREATE INDEX idx_mv_voronoi_poz_area
    ON mv_voronoi_poz (area_m2 DESC);


-- ---- mv_sor_reachability --------------------------------------------------
-- Reachability of every reachable vertex from the nearest SOR hospital
-- within a 25 km cost budget. Used by S2 Q5/Q6 to avoid running
-- pgr_drivingDistance twice in the same query.
--
-- NOTE: with the synthetic 5 km seed grid (88 vertices) the result is coarse.
-- Run scripts/import_osm.sh first for realistic data, then REFRESH this MV.
DROP MATERIALIZED VIEW IF EXISTS mv_sor_reachability CASCADE;
CREATE MATERIALIZED VIEW mv_sor_reachability AS
WITH hospital_vertices AS (
    SELECT v.id::BIGINT AS vertex_id
    FROM szpitale_sor s
    CROSS JOIN LATERAL (
        SELECT id FROM drogi_vertices ORDER BY geom <-> s.geom LIMIT 1
    ) v
)
SELECT pgd.node                  AS vertex_id,
       MIN(pgd.agg_cost)         AS min_koszt_m
FROM pgr_drivingDistance(
    'SELECT id, source, target, cost, reverse_cost FROM drogi_topo',
    ARRAY(SELECT vertex_id FROM hospital_vertices)::BIGINT[],
    25000, true
) pgd
GROUP BY pgd.node;

CREATE UNIQUE INDEX idx_mv_sor_reachability_vertex
    ON mv_sor_reachability (vertex_id);


-- Refresh planner statistics on the new MVs
ANALYZE mv_pokrycie_poz_1km;
ANALYZE mv_voronoi_poz;
ANALYZE mv_sor_reachability;
