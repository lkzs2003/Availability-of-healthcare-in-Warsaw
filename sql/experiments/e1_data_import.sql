-- E1: Poprawność importu danych
-- Metryka: liczba rekordów i zgodność geometrii (SRID, walidacja)

SELECT 'dzielnice'              AS tabela, COUNT(*)        AS liczba,
       COUNT(*) FILTER (WHERE NOT ST_IsValid(geom))        AS invalid_geom,
       COUNT(DISTINCT ST_SRID(geom))                       AS srids,
       MIN(ST_SRID(geom))                                  AS srid
FROM dzielnice
UNION ALL
SELECT 'demografia_dzielnice', COUNT(*),
       0, 0, NULL
FROM demografia_dzielnice
UNION ALL
SELECT 'przychodnie_poz', COUNT(*),
       COUNT(*) FILTER (WHERE NOT ST_IsValid(geom)),
       COUNT(DISTINCT ST_SRID(geom)),
       MIN(ST_SRID(geom))
FROM przychodnie_poz
UNION ALL
SELECT 'szpitale_sor', COUNT(*),
       COUNT(*) FILTER (WHERE NOT ST_IsValid(geom)),
       COUNT(DISTINCT ST_SRID(geom)),
       MIN(ST_SRID(geom))
FROM szpitale_sor
UNION ALL
SELECT 'apteki', COUNT(*),
       COUNT(*) FILTER (WHERE NOT ST_IsValid(geom)),
       COUNT(DISTINCT ST_SRID(geom)),
       MIN(ST_SRID(geom))
FROM apteki
UNION ALL
SELECT 'drogi_vertices', COUNT(*),
       COUNT(*) FILTER (WHERE NOT ST_IsValid(geom)),
       COUNT(DISTINCT ST_SRID(geom)),
       MIN(ST_SRID(geom))
FROM drogi_vertices
UNION ALL
SELECT 'drogi_topo', COUNT(*),
       COUNT(*) FILTER (WHERE NOT ST_IsValid(geom)),
       COUNT(DISTINCT ST_SRID(geom)),
       MIN(ST_SRID(geom))
FROM drogi_topo;

-- Walidacja: czy dzielnice NIE nakładają się (warunek dla S1/S4/S6)
SELECT 'overlapping_districts' AS test,
       COUNT(*) AS pary_z_naklady
FROM dzielnice a JOIN dzielnice b
  ON a.id < b.id
 AND ST_Intersects(a.geom, b.geom)
 AND ST_Area(ST_Intersection(a.geom, b.geom)) > 1.0;   -- tolerancja 1 m²

-- Walidacja topologii grafu (pgRouting)
-- pgr_analyzeGraph deprecated since v3.0; use pgr_connectedComponents instead
SELECT 'connected_components' AS metric,
       component,
       COUNT(*) AS vertices_in_component
FROM pgr_connectedComponents(
    'SELECT id, source, target, cost FROM drogi_topo'
)
GROUP BY component
ORDER BY 3 DESC;
-- Expect 1 dominant component; many small components → graph is fragmented
