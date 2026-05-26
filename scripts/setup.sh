#!/usr/bin/env bash
#
# scripts/setup.sh — kompletna inicjalizacja środowiska
#
# Pełny pipeline od świeżego klonu repo do stanu zgodnego ze sprawozdaniem
# końcowym:
#   1. docker compose up -d --build    — kontener PostGIS + pgAdmin
#                                        (auto-load sql/init/*.sql = seed)
#   2. import_real_data.sh             — pobiera real GUS/OSM/PRG i nadpisuje seed
#                                        (231 POZ, ~586 apt, 4 SOR, 18 dz, 1.86M pop)
#   3. import_apteki.sh                — pobiera 673 apteki z OSM bbox
#   4. V1.1                            — 14 SOR (NFZ+RPWDL), demografia 1.812M,
#                                        kolumna `dzielnica`, spatial join, indeksy
#   5. V1.2                            — usuwa 91 placówek poza Warszawą
#                                        (final stan: 582 apt / 231 POZ / 14 SOR)
#
# Stan po zakończeniu = stan opisywany w docs/reports/sprawozdanie_koncowe.pdf
#
# Uruchomienie:    ./scripts/setup.sh
# Wymagania:       Docker Desktop, python3, curl, ~10 min (z cache: ~3 min)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

# .env
[[ -f .env ]] || cp .env.example .env

DB_SERVICE="${DB_SERVICE:-db}"
DB_USER="${POSTGRES_USER:-postgres}"
DB_NAME="${POSTGRES_DB:-warszawa_health}"

step() { echo -e "\n\033[1;34m===\033[0m $*"; }

# ----------------------------------------------- 1. Docker stack
step "Krok 1/5 — uruchomienie kontenerów (PostGIS + pgAdmin)"
docker compose up -d --build
echo "  oczekuje na zdrowy kontener db..."
for _ in $(seq 1 60); do
    if docker compose exec -T "$DB_SERVICE" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
        echo "  -> db healthy"; break
    fi
    sleep 2
done

# ----------------------------------------------- 2. Real data (GUS/OSM/PRG)
step "Krok 2/5 — pobranie real danych z GUS + OSM + PRG (231 POZ, 4 SOR, 18 dz)"
./scripts/import_real_data.sh

# ----------------------------------------------- 3. Apteki z OSM
step "Krok 3/5 — pobranie 673 aptek z OSM bbox"
./scripts/import_apteki.sh

# ----------------------------------------------- 4. Migracja V1.1
step "Krok 4/5 — migracja V1.1 (14 SOR z NFZ+RPWDL, demografia 2023, dzielnica)"
docker compose exec -T "$DB_SERVICE" \
    psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 \
    < sql/migrations/V1.1__enrich_healthcare_and_demographics.sql > /dev/null

# ----------------------------------------------- 5. Migracja V1.2
step "Krok 5/5 — migracja V1.2 (usunięcie 91 placówek spoza Warszawy)"
docker compose exec -T "$DB_SERVICE" \
    psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 \
    < sql/migrations/V1.2__cleanup_out_of_warsaw_points.sql > /dev/null

# ----------------------------------------------- Weryfikacja
step "Weryfikacja stanu końcowego"
docker compose exec -T "$DB_SERVICE" \
    psql -U "$DB_USER" -d "$DB_NAME" -At -c "
SELECT 'apteki=' || COUNT(*) FROM apteki;
SELECT 'przychodnie_poz=' || COUNT(*) FROM przychodnie_poz;
SELECT 'szpitale_sor=' || COUNT(*) FROM szpitale_sor;
SELECT 'dzielnice=' || COUNT(*) FROM dzielnice;
SELECT 'populacja_2023=' || SUM(ludnosc) FROM demografia_dzielnice WHERE rok = 2023;
SELECT 'indeksy=' || COUNT(*) FROM pg_indexes WHERE schemaname = 'public';"

echo -e "\n\033[1;32mGotowe.\033[0m  Stan bazy odpowiada sprawozdaniu końcowemu."
echo "  Sprawozdanie:  docs/reports/sprawozdanie_koncowe.pdf"
echo "  pgAdmin:       http://127.0.0.1:8080 (admin@localhost.pl / admin)"
echo "  Scenariusze:   ./scripts/run_scenario.sh <1..6>"
