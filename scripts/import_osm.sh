#!/usr/bin/env bash
# Import Warsaw OSM road network and copy into drogi_topo / drogi_vertices.
# Runs osm2pgrouting INSIDE the container so no host install is required.
# Prerequisites: Docker running, container up (`docker compose up -d`).
#
# Data source: Geofabrik Poland extract (mazowieckie region, clipped to Warsaw)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="${ROOT_DIR}/data/osm"

set -a
[[ -f "${ROOT_DIR}/.env" ]] && source "${ROOT_DIR}/.env"
set +a

: "${POSTGRES_DB:=warszawa_health}"
: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_PASSWORD:=postgres}"

COMPOSE="docker compose"
SERVICE="db"

OSM_URL="https://download.geofabrik.de/europe/poland/mazowieckie-latest.osm.pbf"
OSM_PBF="${DATA_DIR}/mazowieckie-latest.osm.pbf"

mkdir -p "$DATA_DIR"

echo "=== Step 1: Download OSM extract (Mazowieckie) ==="
if [[ ! -f "$OSM_PBF" ]]; then
    echo "Downloading ${OSM_URL} ..."
    if command -v wget &>/dev/null; then
        wget -q --show-progress -O "$OSM_PBF" "$OSM_URL"
    else
        curl -L --progress-bar -o "$OSM_PBF" "$OSM_URL"
    fi
else
    echo "Cached: ${OSM_PBF}"
fi

echo ""
echo "=== Step 2: Clip to Warsaw bbox (using osmium, baked into image) ==="
# Warsaw bbox (WGS84): W=20.85 S=52.10 E=21.27 N=52.37
# osmium-tool is pre-installed in Dockerfile for immutability
$COMPOSE exec -T "$SERVICE" osmium extract \
    --bbox 20.85,52.10,21.27,52.37 \
    --overwrite \
    -o /data/osm/warszawa.osm.pbf \
    /data/osm/mazowieckie-latest.osm.pbf

# osm2pgrouting needs XML (.osm) — convert the clipped PBF
$COMPOSE exec -T "$SERVICE" osmium cat \
    --overwrite \
    -o /data/osm/warszawa.osm \
    /data/osm/warszawa.osm.pbf

echo ""
echo "=== Step 3: Drop synthetic seed road network ==="
$COMPOSE exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" "$SERVICE" \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -c "TRUNCATE drogi_topo, drogi_vertices RESTART IDENTITY CASCADE;"

echo ""
echo "=== Step 4: Import with osm2pgrouting (creates ways/ways_vertices_pgr) ==="
# Password is passed via PGPASSWORD env var (not CLI flag) so it never appears in `ps -ef`
$COMPOSE exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" "$SERVICE" \
    osm2pgrouting \
        --file     /data/osm/warszawa.osm \
        --conf     /usr/share/osm2pgrouting/mapconfig_for_cars.xml \
        --dbname   "$POSTGRES_DB" \
        --username "$POSTGRES_USER" \
        --host     localhost \
        --port     5432 \
        --clean

echo ""
echo "=== Step 5: Copy into drogi_topo/drogi_vertices with reprojection to EPSG:2180 ==="
$COMPOSE exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" "$SERVICE" \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 <<'SQL'
-- Copy vertices (reproject EPSG:4326 → EPSG:2180)
INSERT INTO drogi_vertices (id, geom)
SELECT id, ST_Transform(the_geom, 2180)
FROM ways_vertices_pgr;

-- Copy edges; cost recomputed from reprojected geometry (metres).
-- ST_LineMerge collapses MULTILINESTRING (relations) to LINESTRING when topologically
-- continuous; ST_Force2D drops any 3D Z/M dimensions OSM may have introduced.
-- Without these, the hard cast ::geometry(LINESTRING,2180) crashes on multi-part edges.
INSERT INTO drogi_topo (source, target, cost, reverse_cost, geom)
SELECT w.source,
       w.target,
       ST_Length(ST_Transform(w.the_geom, 2180)) AS cost,
       CASE WHEN w.reverse_cost < 0
            THEN -1
            ELSE ST_Length(ST_Transform(w.the_geom, 2180))
       END AS reverse_cost,
       ST_MakeValid(
           ST_Force2D(ST_LineMerge(ST_Transform(w.the_geom, 2180)))
       )::geometry(LINESTRING, 2180) AS geom
FROM ways w
WHERE w.source IS NOT NULL AND w.target IS NOT NULL;  -- skip orphan edges to satisfy FK

-- Drop osm2pgrouting staging tables
DROP TABLE IF EXISTS ways, ways_vertices_pgr, configuration,
                      osm_nodes, osm_relations, osm_ways,
                      pointsofinterest CASCADE;

REINDEX INDEX idx_drogi_topo_geom;
REINDEX INDEX idx_drogi_topo_source;
REINDEX INDEX idx_drogi_topo_target;
REINDEX INDEX idx_drogi_vertices_geom;
ANALYZE drogi_topo;
ANALYZE drogi_vertices;

SELECT 'edges'    AS tabela, COUNT(*) AS liczba FROM drogi_topo
UNION ALL
SELECT 'vertices' AS tabela, COUNT(*)           FROM drogi_vertices;

-- Verify graph connectivity: a healthy OSM road network for one city
-- should produce one dominant component covering >95% of vertices.
-- If you see many small components, edges were lost during import.
WITH comps AS (
    SELECT component, COUNT(*) AS verts
    FROM pgr_connectedComponents('SELECT id, source, target, cost FROM drogi_topo')
    GROUP BY component
)
SELECT 'connectivity'                                                  AS metric,
       COUNT(*)                                                        AS total_components,
       MAX(verts)                                                      AS biggest_component_verts,
       ROUND((MAX(verts) * 100.0 / SUM(verts))::NUMERIC, 1)            AS biggest_pct
FROM comps;

-- Refresh dependent materialised views (mv_sor_reachability uses drogi_topo)
REFRESH MATERIALIZED VIEW mv_sor_reachability;
SQL

echo ""
echo "Done. Real OSM road network imported and reprojected to EPSG:2180."
