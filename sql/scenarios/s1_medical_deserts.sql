-- ============================================================
-- S1 — Pustynie medyczne (Medical deserts) — 7 zapytań
-- Pytanie: które obszary Warszawy leżą >1 km od najbliższej
-- przychodni POZ i które dzielnice są najbardziej dotknięte?
--
-- Wykorzystuje widok zmaterializowany mv_pokrycie_poz_1km
-- (definicja: sql/init/04_materialized_views.sql).
-- Po zmianach w przychodniach POZ wykonaj:
--   REFRESH MATERIALIZED VIEW mv_pokrycie_poz_1km;
-- ============================================================

-- Q1: Lista wszystkich przychodni POZ
SELECT id, nazwa, adres,
       ST_X(geom) AS x_pl92,
       ST_Y(geom) AS y_pl92
FROM przychodnie_poz
ORDER BY nazwa;


-- Q2: Bufor 1 km wokół każdej przychodni
SELECT id, nazwa,
       ST_Buffer(geom, 1000) AS zasieg_1km
FROM przychodnie_poz;


-- Q3: Suma buforów — pokryty obszar miasta (z MV)
SELECT geom AS obszar_pokryty
FROM mv_pokrycie_poz_1km;


-- Q4: Fizyczna mapa pustyń medycznych
--     (kluczowy krok: ST_Difference miasto minus pokrycie)
WITH miasto AS (
    SELECT ST_Union(geom) AS g FROM dzielnice
)
SELECT ST_Difference(m.g, p.geom) AS pustynie
FROM miasto m, mv_pokrycie_poz_1km p;


-- Q5: Powierzchnia pustyni (km²) per dzielnica
WITH pustynie AS (
    SELECT d.id, d.nazwa,
           ST_Difference(d.geom, p.geom) AS pustynia_geom
    FROM dzielnice d, mv_pokrycie_poz_1km p
)
SELECT nazwa,
       ROUND((ST_Area(pustynia_geom) / 1e6)::NUMERIC, 3) AS pustynia_km2
FROM pustynie
ORDER BY pustynia_km2 DESC;


-- Q6: Procent powierzchni dzielnicy będący pustynią
WITH pustynie AS (
    SELECT d.id, d.nazwa, d.powierzchnia_km2,
           ST_Difference(d.geom, p.geom) AS pustynia_geom
    FROM dzielnice d, mv_pokrycie_poz_1km p
)
SELECT nazwa,
       ROUND((ST_Area(pustynia_geom) / 1e6)::NUMERIC, 3)            AS pustynia_km2,
       ROUND(
           (ST_Area(pustynia_geom) / (powierzchnia_km2 * 1e6) * 100)::NUMERIC
       , 1) AS pustynia_pct
FROM pustynie
ORDER BY pustynia_pct DESC;


-- Q7: Szacunkowa liczba mieszkańców na pustyniach — ranking dzielnic
--     Założenie: równomierne rozproszenie ludności w dzielnicy
WITH pustynie AS (
    SELECT d.id, d.nazwa, d.powierzchnia_km2,
           ST_Difference(d.geom, p.geom) AS pustynia_geom
    FROM dzielnice d, mv_pokrycie_poz_1km p
),
statystyki AS (
    SELECT p.nazwa,
           ST_Area(p.pustynia_geom) / 1e6             AS pustynia_km2,
           ST_Area(p.pustynia_geom)
               / (p.powierzchnia_km2 * 1e6)            AS udzial,
           dd.ludnosc
    FROM pustynie p
    JOIN demografia_dzielnice dd ON dd.dzielnica_id = p.id AND dd.rok = 2023
)
SELECT nazwa,
       ROUND(pustynia_km2::NUMERIC, 3)             AS pustynia_km2,
       ROUND((udzial * 100)::NUMERIC, 1)           AS pustynia_pct,
       ROUND((ludnosc * udzial)::NUMERIC)          AS szac_mieszkancy_pustynia,
       RANK() OVER (ORDER BY ludnosc * udzial DESC) AS ranking
FROM statystyki
ORDER BY ranking;
