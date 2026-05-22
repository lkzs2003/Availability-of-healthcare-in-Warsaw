#!/usr/bin/env bash
# Run one of the 6 experiments (E1–E6) against the running database.
# Usage: ./scripts/run_experiment.sh <experiment_number>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

set -a
[[ -f "${ROOT_DIR}/.env" ]] && source "${ROOT_DIR}/.env"
set +a

: "${POSTGRES_DB:=warszawa_health}"
: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_PASSWORD:=postgres}"

if [[ $# -lt 1 ]]; then
    cat <<EOF
Usage: $0 <experiment_number>

Available experiments:
  1 — Poprawność importu danych (record counts, validity, SRID)
  2 — Poprawność 6 scenariuszy (runs all scenarios end-to-end)
  3 — Wpływ indeksu GiST (EXPLAIN ANALYZE, N=10^3..10^5)
  4 — Wydajność pgRouting (500 m vs 1 km grid)
  5 — Studium przypadku S1 (materialised views)
  6 — Powtarzalność środowiska (clean rebuild timing)
EOF
    exit 1
fi

case "$1" in
    1) SQL="${ROOT_DIR}/sql/experiments/e1_data_import.sql" ;;
    2)
        echo "=== E2: Running all 6 scenarios ==="
        echo "⚠️  NOTE: S2 (SOR routing) uses synthetic 5 km grid (88 vertices)."
        echo "         Results are unreliable until OSM import is run."
        echo "         For realistic S2 output: ./scripts/import_osm.sh"
        echo ""
        for i in 1 2 3 4 5 6; do
            echo "--- S${i} ---"
            "${SCRIPT_DIR}/run_scenario.sh" "$i" > "/tmp/e2_s${i}.out" 2>&1 \
                && echo "S${i} OK ($(wc -l < /tmp/e2_s${i}.out) lines)" \
                || { echo "S${i} FAILED — see /tmp/e2_s${i}.out"; exit 1; }
        done
        exit 0
        ;;
    3) SQL="${ROOT_DIR}/sql/experiments/e3_gist_impact.sql" ;;
    4) SQL="${ROOT_DIR}/sql/experiments/e4_pgrouting_perf.sql" ;;
    5) SQL="${ROOT_DIR}/sql/experiments/e5_case_study_s1.sql" ;;
    6)
        echo "=== E6: Reproducibility — clean rebuild timing ==="
        cd "$ROOT_DIR"
        docker compose down -v
        START=$(date +%s)
        docker compose up -d --build
        # Wait for healthcheck to pass — bounded retry (max 120 s) to avoid infinite hang
        MAX_TRIES=120
        TRY=0
        until docker compose exec -T db pg_isready -U "$POSTGRES_USER" >/dev/null 2>&1; do
            TRY=$((TRY + 1))
            if [[ $TRY -ge $MAX_TRIES ]]; then
                echo "ERROR: pg_isready did not succeed after ${MAX_TRIES}s — aborting." >&2
                docker compose logs db | tail -50 >&2
                exit 1
            fi
            sleep 1
        done
        END=$(date +%s)
        echo "Elapsed: $((END - START)) seconds (target: < 900 s = 15 min)"
        exit 0
        ;;
    *) echo "Unknown experiment: $1"; exit 1 ;;
esac

# Run E1/E3/E4/E5 inside the container — no host psql dependency,
# matches the pattern used by E2/E6 and run_scenario.sh
docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" db \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" < "$SQL"
