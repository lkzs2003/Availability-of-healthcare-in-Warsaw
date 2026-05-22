-- E5: Studium przypadku S1 — pustynie medyczne
-- Metryka: mapa pustyń + ranking dzielnic + komentarz analityczny
-- Ten skrypt produkuje materializowany widok gotowy do wizualizacji w QGIS.

DROP MATERIALIZED VIEW IF EXISTS mv_pustynie_medyczne CASCADE;

-- Korzysta z mv_pokrycie_poz_1km (sql/init/04_materialized_views.sql).
-- Po zmianach w przychodniach POZ wykonaj:
--   REFRESH MATERIALIZED VIEW mv_pokrycie_poz_1km;
--   REFRESH MATERIALIZED VIEW mv_pustynie_medyczne;
CREATE MATERIALIZED VIEW mv_pustynie_medyczne AS
WITH pustynie AS (
    SELECT d.id,
           d.nazwa,
           d.powierzchnia_km2,
           ST_Multi(ST_Difference(d.geom, p.geom))::geometry(MULTIPOLYGON, 2180) AS geom
    FROM dzielnice d, mv_pokrycie_poz_1km p
)
SELECT p.id,
       p.nazwa,
       p.geom,
       ROUND((ST_Area(p.geom) / 1e6)::NUMERIC, 3)
           AS pustynia_km2,
       ROUND((ST_Area(p.geom)
              / (p.powierzchnia_km2 * 1e6) * 100)::NUMERIC, 1)
           AS pustynia_pct,
       dd.ludnosc,
       ROUND((dd.ludnosc * ST_Area(p.geom)
              / (p.powierzchnia_km2 * 1e6))::NUMERIC)
           AS szac_mieszkancy_pustynia,
       RANK() OVER (
           ORDER BY dd.ludnosc * ST_Area(p.geom)
                  / (p.powierzchnia_km2 * 1e6) DESC
       ) AS ranking
FROM pustynie p
JOIN demografia_dzielnice dd ON dd.dzielnica_id = p.id AND dd.rok = 2023;

CREATE INDEX idx_mv_pustynie_geom ON mv_pustynie_medyczne USING GiST (geom);

-- Podsumowanie
SELECT nazwa, pustynia_km2, pustynia_pct, szac_mieszkancy_pustynia, ranking
FROM mv_pustynie_medyczne
ORDER BY ranking;

-- Mapa ogólnomiejska: jedna geometria pustyń dla całej Warszawy
DROP MATERIALIZED VIEW IF EXISTS mv_pustynie_globalnie CASCADE;
CREATE MATERIALIZED VIEW mv_pustynie_globalnie AS
WITH miasto AS (SELECT ST_Union(geom) AS g FROM dzielnice)
SELECT 1 AS id,
       ST_Multi(ST_Difference(m.g, p.geom))::geometry(MULTIPOLYGON, 2180) AS geom,
       ROUND((ST_Area(ST_Difference(m.g, p.geom)) / 1e6)::NUMERIC, 2) AS pow_km2
FROM miasto m, mv_pokrycie_poz_1km p;

CREATE INDEX idx_mv_pustynie_globalnie_geom ON mv_pustynie_globalnie USING GiST (geom);
