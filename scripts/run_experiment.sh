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
: "${DB_PORT:=5432}"
: "${DB_HOST:=localhost}"

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
        # Wait for healthcheck to pass
        until docker compose exec -T db pg_isready -U "$POSTGRES_USER" >/dev/null 2>&1; do
            sleep 1
        done
        END=$(date +%s)
        echo "Elapsed: $((END - START)) seconds (target: < 900 s = 15 min)"
        exit 0
        ;;
    *) echo "Unknown experiment: $1"; exit 1 ;;
esac

PGPASSWORD="$POSTGRES_PASSWORD" psql \
    -h "$DB_HOST" -p "$DB_PORT" \
    -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -f "$SQL"
