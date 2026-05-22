#!/usr/bin/env bash
# import_real_data.sh — pobierz rzeczywiste dane z RPWDL/GUS BDL/OSM/PRG
# i wstaw do bazy uruchomionej w `docker compose`.
#
# Wymagania: python3 (stdlib), curl, jq (opcjonalne)
# Cache w data/cache/ — re-użycie surowych downloads między uruchomieniami.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

set -a
[[ -f "${ROOT_DIR}/.env" ]] && source "${ROOT_DIR}/.env"
set +a

: "${POSTGRES_DB:=warszawa_health}"
: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_PASSWORD:=postgres}"

# Verify DB is running
if ! docker compose ps --status running --services 2>/dev/null | grep -q '^db$'; then
    echo "ERROR: db service is not running. Run: docker compose up -d" >&2
    exit 1
fi

echo "=== Step 1/3: Fetch from public APIs (cache in data/cache/) ==="
python3 "${SCRIPT_DIR}/lib/fetch_real_data.py" "$@"

echo ""
echo "=== Step 2/3: Disable refresh triggers (bulk load → one refresh at the end) ==="
docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" db \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 <<'SQL'
ALTER TABLE przychodnie_poz DISABLE TRIGGER USER;
ALTER TABLE dzielnice       DISABLE TRIGGER USER;
ALTER TABLE szpitale_sor    DISABLE TRIGGER USER;
SQL

echo ""
echo "=== Step 3/3: Load real data → apply SQL files in order ==="
cd "$ROOT_DIR"
for f in sql/init/data_real/*.sql; do
    name="$(basename "$f")"
    echo "  applying: $name"
    docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" db \
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 < "$f" \
        | tail -5
done

echo ""
echo "=== Step 4/4: Re-enable triggers + refresh all MVs ==="
docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" db \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 <<'SQL'
ALTER TABLE przychodnie_poz ENABLE TRIGGER USER;
ALTER TABLE dzielnice       ENABLE TRIGGER USER;
ALTER TABLE szpitale_sor    ENABLE TRIGGER USER;

REFRESH MATERIALIZED VIEW mv_pokrycie_poz_1km;
REFRESH MATERIALIZED VIEW mv_voronoi_poz;
REFRESH MATERIALIZED VIEW mv_sor_reachability;

ANALYZE dzielnice;
ANALYZE demografia_dzielnice;
ANALYZE przychodnie_poz;
ANALYZE szpitale_sor;
ANALYZE apteki;

-- Verification summary
SELECT 'dzielnice'        AS tabela, COUNT(*) AS liczba FROM dzielnice
UNION ALL SELECT 'demografia_dzielnice', COUNT(*) FROM demografia_dzielnice
UNION ALL SELECT 'szpitale_sor',    COUNT(*) FROM szpitale_sor
UNION ALL SELECT 'przychodnie_poz', COUNT(*) FROM przychodnie_poz
UNION ALL SELECT 'apteki',          COUNT(*) FROM apteki
ORDER BY tabela;
SQL

echo ""
echo "Done. Real data loaded. Run scenarios:"
echo "  ./scripts/run_scenario.sh 1   # Pustynie medyczne (real POZ data)"
echo "  ./scripts/run_scenario.sh 4   # Gęstość aptek (real OSM pharmacies)"
