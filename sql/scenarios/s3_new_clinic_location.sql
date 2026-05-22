-- ============================================================
-- S3 — Lokalizacja nowej przychodni POZ — 5 zapytań
-- Pytanie: gdzie otworzyć nową przychodnię, aby maksymalnie
-- poprawić dostępność?
--
-- Wykorzystuje widok zmaterializowany mv_voronoi_poz
-- (definicja: sql/init/04_materialized_views.sql).
-- Po zmianach w przychodniach POZ lub dzielnicach wykonaj:
--   REFRESH MATERIALIZED VIEW mv_voronoi_poz;
-- ============================================================

-- Q1: Diagram Voronoi dla istniejących przychodni POZ (z MV — pocięte komórki)
SELECT cell_id, strefa_clip AS strefa_voronoi
FROM mv_voronoi_poz
ORDER BY cell_id;


-- Q2: Ranking stref Voronoi według powierzchni
--     (duża strefa Voronoi = słaba dostępność)
SELECT cell_id,
       ROUND((area_m2 / 1e6)::NUMERIC, 3) AS powierzchnia_km2,
       strefa_clip
FROM mv_voronoi_poz
ORDER BY area_m2 DESC;


-- Q3: Centroid największej strefy Voronoi jako kandydat
SELECT centroid                              AS kandydat_lokalizacja,
       ROUND((area_m2 / 1e6)::NUMERIC, 3)    AS pow_km2
FROM mv_voronoi_poz
ORDER BY area_m2 DESC
LIMIT 1;


-- Q4: Szacunek mieszkańców w buforze 1 km wokół kandydata
--     (proporcja przecinającej się powierzchni z dzielnicą)
WITH kandydat AS (
    SELECT ST_Buffer(centroid, 1000) AS bufor_1km
    FROM mv_voronoi_poz
    ORDER BY area_m2 DESC
    LIMIT 1
)
SELECT d.nazwa,
       dd.ludnosc,
       ROUND((ST_Area(ST_Intersection(d.geom, k.bufor_1km))
              / ST_Area(d.geom) * dd.ludnosc)::NUMERIC) AS szac_mieszkancy
FROM dzielnice d
JOIN demografia_dzielnice dd ON dd.dzielnica_id = d.id AND dd.rok = 2023
CROSS JOIN kandydat k
WHERE ST_Intersects(d.geom, k.bufor_1km)
ORDER BY szac_mieszkancy DESC;


-- Q5: Top 5 kandydatów z porównaniem (powierzchnia strefy + zasięg 1 km)
WITH top_kandydaci AS (
    SELECT row_number() OVER (ORDER BY area_m2 DESC) AS rank_nr,
           centroid AS kandydat,
           ST_Buffer(centroid, 1000) AS bufor_1km,
           area_m2
    FROM mv_voronoi_poz
    ORDER BY area_m2 DESC
    LIMIT 5
),
zasieg AS (
    SELECT tk.rank_nr, tk.kandydat,
           ROUND((tk.area_m2 / 1e6)::NUMERIC, 3) AS pow_strefy_km2,
           -- ROUND AFTER SUM to avoid accumulating rounding errors
           -- (rounding before summing can lose up to 0.5 per district × 18 districts = ±9 person error)
           COALESCE(ROUND(
               SUM(ST_Area(ST_Intersection(d.geom, tk.bufor_1km))
                   / ST_Area(d.geom) * dd.ludnosc)::NUMERIC
           ), 0) AS szac_mieszkancy_1km
    FROM top_kandydaci tk
    LEFT JOIN dzielnice d
        ON ST_Intersects(d.geom, tk.bufor_1km)
    LEFT JOIN demografia_dzielnice dd
        ON dd.dzielnica_id = d.id AND dd.rok = 2023
    GROUP BY tk.rank_nr, tk.kandydat, tk.area_m2
)
SELECT rank_nr,
       ST_X(kandydat) AS x_pl92,
       ST_Y(kandydat) AS y_pl92,
       pow_strefy_km2,
       szac_mieszkancy_1km
FROM zasieg
ORDER BY rank_nr;
