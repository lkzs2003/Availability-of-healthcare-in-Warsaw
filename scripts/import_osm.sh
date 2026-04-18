#!/usr/bin/env bash
# Import Warsaw OSM road network into drogi_topo using osm2pgrouting.
# Run this AFTER the container is up and the schema is initialised.
# Requires: osm2pgrouting, wget/curl, Docker running.
#
# Data source: Geofabrik Poland extract (mazowieckie region)
# osm2pgrouting docs: https://github.com/pgRouting/osm2pgrouting

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="${ROOT_DIR}/data/osm"

source "${ROOT_DIR}/.env" 2>/dev/null || true

DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${POSTGRES_DB:-warszawa_health}"
DB_USER="${POSTGRES_USER:-postgres}"
DB_PASS="${POSTGRES_PASSWORD:-postgres}"

OSM_URL="https://download.geofabrik.de/europe/poland/mazowieckie-latest.osm.pbf"
OSM_FILE="${DATA_DIR}/mazowieckie-latest.osm.pbf"

mkdir -p "$DATA_DIR"

echo "=== Step 1: Download OSM extract (Mazowieckie) ==="
if [[ ! -f "$OSM_FILE" ]]; then
    echo "Downloading ${OSM_URL} ..."
    wget -q --show-progress -O "$OSM_FILE" "$OSM_URL"
else
    echo "File already exists: ${OSM_FILE}"
fi

echo ""
echo "=== Step 2: Clip to Warsaw bounding box ==="
# Warsaw bbox (WGS84): W=20.85 S=52.10 E=21.27 N=52.37
CLIPPED="${DATA_DIR}/warszawa.osm"
if command -v osmosis &>/dev/null; then
    osmosis --read-pbf "$OSM_FILE" \
        --bounding-box top=52.37 left=20.85 bottom=52.10 right=21.27 \
        --write-xml "$CLIPPED"
elif command -v osmium &>/dev/null; then
    osmium extract --bbox 20.85,52.10,21.27,52.37 \
        "$OSM_FILE" -o "$CLIPPED" --overwrite
else
    echo "Warning: osmosis/osmium not found. Using full extract (slower import)."
    CLIPPED="$OSM_FILE"
fi

echo ""
echo "=== Step 3: Drop synthetic seed road network ==="
PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -c "TRUNCATE drogi_topo, drogi_vertices RESTART IDENTITY CASCADE;"

echo ""
echo "=== Step 4: Import with osm2pgrouting ==="
osm2pgrouting \
    --file     "$CLIPPED" \
    --conf     "/usr/share/osm2pgrouting/mapconfig_for_cars.xml" \
    --dbname   "$DB_NAME" \
    --username "$DB_USER" \
    --password "$DB_PASS" \
    --host     "$DB_HOST" \
    --port     "$DB_PORT" \
    --prefix   "drogi_" \
    --clean

echo ""
echo "=== Step 5: Re-project to EPSG:2180 and rebuild indices ==="
PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" << 'SQL'
-- osm2pgrouting creates tables in EPSG:4326 by default; reproject to PL-1992
UPDATE drogi_topo  SET geom = ST_Transform(ST_SetSRID(geom, 4326), 2180);
UPDATE drogi_vertices SET geom = ST_Transform(ST_SetSRID(geom, 4326), 2180);
SELECT UpdateGeometrySRID('drogi_topo',     'geom', 2180);
SELECT UpdateGeometrySRID('drogi_vertices', 'geom', 2180);

-- Recalculate cost = length in metres in PL-1992
UPDATE drogi_topo SET cost = ST_Length(geom), reverse_cost = ST_Length(geom);

-- Rebuild spatial indices
REINDEX INDEX idx_drogi_topo_geom;
REINDEX INDEX idx_drogi_vertices_geom;

SELECT COUNT(*) AS edges   FROM drogi_topo;
SELECT COUNT(*) AS vertices FROM drogi_vertices;
SQL

echo ""
echo "Done. Real OSM road network imported and reprojected to EPSG:2180."
