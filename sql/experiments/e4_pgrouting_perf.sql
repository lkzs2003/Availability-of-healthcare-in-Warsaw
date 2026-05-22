-- E4: Wydajność pgRouting
-- Metryka: czas wykonania scenariusza S2 Q5 dla siatki 500 m vs 1 km.

\echo '=== S2.5 — siatka 500 m ==='
EXPLAIN (ANALYZE, BUFFERS, TIMING)
WITH hospital_vertices AS (
    SELECT v.id::BIGINT AS vertex_id
    FROM szpitale_sor s
    CROSS JOIN LATERAL (
        SELECT id FROM drogi_vertices ORDER BY geom <-> s.geom LIMIT 1
    ) v
),
reachability AS (
    SELECT pgd.node AS vertex_id, MIN(pgd.agg_cost) AS min_koszt_m
    FROM pgr_drivingDistance(
        'SELECT id, source, target, cost, reverse_cost FROM drogi_topo',
        ARRAY(SELECT vertex_id FROM hospital_vertices)::BIGINT[],
        25000, true
    ) pgd
    GROUP BY pgd.node
),
bbox AS (SELECT * FROM warszawa_bbox),
grid AS (
    SELECT ST_SetSRID(ST_Point(x, y), 2180) AS geom
    FROM bbox b,
         LATERAL generate_series(b.xmin::INT, b.xmax::INT, 500) x,
         LATERAL generate_series(b.ymin::INT, b.ymax::INT, 500) y
)
SELECT COUNT(*) AS komorki_z_czasem
FROM grid g
CROSS JOIN LATERAL (
    SELECT id FROM drogi_vertices ORDER BY geom <-> g.geom LIMIT 1
) v
LEFT JOIN reachability r ON r.vertex_id = v.id;

\echo '=== S2.5 — siatka 1 km ==='
EXPLAIN (ANALYZE, BUFFERS, TIMING)
WITH hospital_vertices AS (
    SELECT v.id::BIGINT AS vertex_id
    FROM szpitale_sor s
    CROSS JOIN LATERAL (
        SELECT id FROM drogi_vertices ORDER BY geom <-> s.geom LIMIT 1
    ) v
),
reachability AS (
    SELECT pgd.node AS vertex_id, MIN(pgd.agg_cost) AS min_koszt_m
    FROM pgr_drivingDistance(
        'SELECT id, source, target, cost, reverse_cost FROM drogi_topo',
        ARRAY(SELECT vertex_id FROM hospital_vertices)::BIGINT[],
        25000, true
    ) pgd
    GROUP BY pgd.node
),
bbox AS (SELECT * FROM warszawa_bbox),
grid AS (
    SELECT ST_SetSRID(ST_Point(x, y), 2180) AS geom
    FROM bbox b,
         LATERAL generate_series(b.xmin::INT, b.xmax::INT, 1000) x,
         LATERAL generate_series(b.ymin::INT, b.ymax::INT, 1000) y
)
SELECT COUNT(*) AS komorki_z_czasem
FROM grid g
CROSS JOIN LATERAL (
    SELECT id FROM drogi_vertices ORDER BY geom <-> g.geom LIMIT 1
) v
LEFT JOIN reachability r ON r.vertex_id = v.id;
