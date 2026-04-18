#!/usr/bin/env bash
# Run one of the 6 analytical scenarios against the running database.
# Usage: ./scripts/run_scenario.sh <scenario_number>
# Example: ./scripts/run_scenario.sh 1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

source "${ROOT_DIR}/.env" 2>/dev/null || true

DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${POSTGRES_DB:-warszawa_health}"
DB_USER="${POSTGRES_USER:-postgres}"

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
echo "Database: ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
echo "---"

PGPASSWORD="${POSTGRES_PASSWORD:-postgres}" psql \
    -h "$DB_HOST" \
    -p "$DB_PORT" \
    -U "$DB_USER" \
    -d "$DB_NAME" \
    -f "$SQL_PATH"
