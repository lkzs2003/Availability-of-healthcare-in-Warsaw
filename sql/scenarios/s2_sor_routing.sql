-- ============================================================
-- S2 — Dostępność SOR po sieci drogowej — 6 zapytań
-- Pytanie: jaki jest czas dojazdu do najbliższego SOR
-- z każdego punktu miasta po faktycznej sieci dróg?
-- Koszt w drogi_topo = długość segmentu w metrach
-- 50 km/h → 1 min = 833 m → 10 min = 8 333 m
--
-- ⚠️  LIMITATION: The synthetic 5 km grid (seed data) has only 88 vertices.
--     Five hospitals snapped via KNN will often collapse to shared vertices.
--     This breaks isochrone granularity in Q4 and makes Q5 unreliable.
--     For meaningful results, run: ./scripts/import_osm.sh
--     to replace the synthetic graph with real OSM road network.
-- ============================================================

-- Q1: Lista szpitali z SOR
SELECT id, nazwa, adres,
       ST_X(geom) AS x_pl92,
       ST_Y(geom) AS y_pl92
FROM szpitale_sor
ORDER BY nazwa;


-- Q2: Mapowanie szpitali na węzły sieci drogowej (KNN <->)
SELECT s.id   AS szpital_id,
       s.nazwa,
       v.id   AS vertex_id,
       ROUND(ST_Distance(s.geom, v.geom)::NUMERIC, 0) AS odl_do_wezla_m
FROM szpitale_sor s
CROSS JOIN LATERAL (
    SELECT id, geom
    FROM drogi_vertices
    ORDER BY geom <-> s.geom
    LIMIT 1
) v
ORDER BY s.id;


-- Q3: Izochrona 10 min (8333 m) dla wybranego szpitala (id=1)
--     Vertex wyliczany automatycznie z KNN — nie wymaga parametru.
\set szpital_id 1

WITH szpital AS (
    SELECT geom FROM szpitale_sor WHERE id = :szpital_id
),
vertex_szpitala AS (
    SELECT v.id::BIGINT AS vid
    FROM drogi_vertices v, szpital s
    ORDER BY v.geom <-> s.geom
    LIMIT 1
)
SELECT ST_ConcaveHull(ST_Collect(v.geom), 0.85) AS izochrona_10min
FROM vertex_szpitala vs,
     pgr_drivingDistance(
         'SELECT id, source, target, cost, reverse_cost FROM drogi_topo',
         vs.vid, 8333, true
     ) pgd
JOIN drogi_vertices v ON v.id = pgd.node;


-- Q4: Izochrony 5 / 10 / 15 min dla wszystkich SOR
WITH hospital_vertices AS (
    SELECT DISTINCT ON (s.id)
        s.id AS szpital_id, s.nazwa, v.id AS vertex_id
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
SELECT szpital_id, nazwa, strefa,
       ST_ConcaveHull(ST_Collect(v.geom), 0.85) AS izochrona
FROM reachable r
JOIN drogi_vertices v ON v.id = r.node
WHERE strefa IS NOT NULL
GROUP BY szpital_id, nazwa, strefa
ORDER BY szpital_id, strefa;


-- Q5: Siatka 500 m × 500 m — czas dojazdu do najbliższego SOR
--
--     Korzysta z mv_sor_reachability (sql/init/04_materialized_views.sql),
--     który raz wylicza pgr_drivingDistance z budżetem 25 km dla wszystkich SOR.
--     Po zmianach w szpitalach/drogach wykonaj:
--       REFRESH MATERIALIZED VIEW mv_sor_reachability;
--     Bbox siatki czytany z warszawa_bbox (single source of truth).
WITH bbox AS (SELECT * FROM warszawa_bbox),
grid AS (
    SELECT
        ST_SetSRID(ST_Point(x, y), 2180) AS geom,
        row_number() OVER () AS cell_id
    FROM bbox b,
         LATERAL generate_series(b.xmin::INT, b.xmax::INT, 500) x,
         LATERAL generate_series(b.ymin::INT, b.ymax::INT, 500) y
),
grid_vertices AS (
    SELECT g.cell_id, g.geom, v.id AS vertex_id,
           ROUND(ST_Distance(g.geom, v.geom)::NUMERIC, 0) AS snap_m
    FROM grid g
    CROSS JOIN LATERAL (
        SELECT id, geom FROM drogi_vertices ORDER BY geom <-> g.geom LIMIT 1
    ) v
)
SELECT gv.cell_id, gv.geom,
       gv.snap_m                                            AS snap_distance_m,
       r.min_koszt_m                                        AS koszt_siec_m,
       (r.min_koszt_m + gv.snap_m)::INT                     AS koszt_total_m,
       ROUND(((r.min_koszt_m + gv.snap_m) / 833.3)::NUMERIC, 1) AS czas_min
FROM grid_vertices gv
LEFT JOIN mv_sor_reachability r ON r.vertex_id = gv.vertex_id
ORDER BY czas_min DESC NULLS FIRST;


-- Q6: Komórki z czasem dojazdu >15 min — obszary krytyczne
--     (ten sam pipeline siatki + MV reachability — tylko inny filtr)
WITH bbox AS (SELECT * FROM warszawa_bbox),
grid AS (
    SELECT ST_SetSRID(ST_Point(x, y), 2180) AS geom
    FROM bbox b,
         LATERAL generate_series(b.xmin::INT, b.xmax::INT, 500) x,
         LATERAL generate_series(b.ymin::INT, b.ymax::INT, 500) y
),
grid_vertices AS (
    SELECT g.geom, v.id AS vertex_id,
           ROUND(ST_Distance(g.geom, v.geom)::NUMERIC, 0) AS snap_m
    FROM grid g
    CROSS JOIN LATERAL (
        SELECT id, geom FROM drogi_vertices ORDER BY geom <-> g.geom LIMIT 1
    ) v
)
SELECT gv.geom,
       gv.snap_m                                           AS snap_distance_m,
       r.min_koszt_m                                       AS koszt_siec_m,
       (r.min_koszt_m + gv.snap_m)::INT                    AS koszt_total_m,
       ROUND(((r.min_koszt_m + gv.snap_m) / 833.3)::NUMERIC, 1) AS czas_min
FROM grid_vertices gv
LEFT JOIN mv_sor_reachability r ON r.vertex_id = gv.vertex_id
WHERE (r.min_koszt_m IS NULL) OR (r.min_koszt_m + gv.snap_m > 12500)  -- > 15 min @ 50 km/h
ORDER BY czas_min DESC NULLS FIRST;
