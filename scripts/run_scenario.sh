#!/usr/bin/env bash
# Run one of the 6 analytical scenarios against the running database.
# Usage: ./scripts/run_scenario.sh <scenario_number>
# Example: ./scripts/run_scenario.sh 1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Load .env with proper export (set -a/set +a ensures all vars are exported)
set -a
[[ -f "${ROOT_DIR}/.env" ]] && source "${ROOT_DIR}/.env"
set +a

: "${POSTGRES_DB:=warszawa_health}"
: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_PASSWORD:=postgres}"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <scenario_number>"
    echo "Available scenarios:"
    echo "  1 — Pustynie medyczne (medical deserts)"
    echo "  2 — Dostępność SOR po sieci drogowej (SOR routing)"
    echo "  3 — Lokalizacja nowej przychodni POZ (new clinic location)"
    echo "  4 — Gęstość aptek względem ludności (pharmacy density)"
    echo "  5 — Najbliższa apteka od punktu (nearest pharmacy)"
    echo "  6 — Placówki w wybranej dzielnicy (district facilities)"
    exit 1
fi

declare -A SCENARIOS=(
    [1]="s1_medical_deserts.sql"
    [2]="s2_sor_routing.sql"
    [3]="s3_new_clinic_location.sql"
    [4]="s4_pharmacy_density.sql"
    [5]="s5_nearest_pharmacy.sql"
    [6]="s6_district_facilities.sql"
)

SCENARIO_NUM="$1"
SCENARIO_FILE="${SCENARIOS[$SCENARIO_NUM]:-}"

if [[ -z "$SCENARIO_FILE" ]]; then
    echo "Error: unknown scenario number '$SCENARIO_NUM'. Choose 1–6."
    exit 1
fi

SQL_PATH="${ROOT_DIR}/sql/scenarios/${SCENARIO_FILE}"

echo "Running scenario S${SCENARIO_NUM}: ${SCENARIO_FILE}"
echo "Database: ${POSTGRES_USER}@db:5432/${POSTGRES_DB}"
echo "---"

# Run inside container via docker compose exec (no host psql dependency)
docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" db \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" < "$SQL_PATH"
