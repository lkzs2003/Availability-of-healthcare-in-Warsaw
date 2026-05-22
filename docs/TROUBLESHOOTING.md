# Troubleshooting

Najczęstsze problemy i ich rozwiązania.

## Docker

### `Cannot connect to the Docker daemon`
Daemon nie działa. Uruchom Docker Desktop (Mac/Windows) lub `sudo systemctl start docker` (Linux).

### Port 5432 zajęty
```bash
# Inny postgres na hoście
sudo lsof -i :5432
# Zmień port w .env: DB_PORT=5433
```

### `db service is not running` z `import_real_data.sh`
```bash
docker compose up -d
docker compose ps   # sprawdź czy "healthy"
```

## SQL

### `ERROR: foreign key constraint "fk_drogi_topo_source"`
FK na `drogi_topo` jest `DEFERRABLE INITIALLY DEFERRED` — walidacja tylko na COMMIT. Jeśli zobaczysz ten błąd przy `import_osm.sh`, znaczy że jakaś krawędź referuje nieistniejący vertex. Sprawdź:
```sql
SELECT COUNT(*) FROM drogi_topo t
LEFT JOIN drogi_vertices v ON v.id = t.source
WHERE v.id IS NULL;
```

### `ERROR: relation "mv_voronoi_poz" does not exist`
Init script 04 nie uruchomił się. Sprawdź logi:
```bash
docker compose logs db | grep -iE 'error|04_materialized'
```
Najprawdopodobniej `przychodnie_poz` było puste w momencie tworzenia MV (`./scripts/import_real_data.sh` zanim seed się załadował). Rozwiązanie:
```bash
docker compose down -v && docker compose up -d --build
```

### `cannot refresh materialized view "mv_voronoi_poz"` (CONCURRENTLY)
Wymaga UNIQUE indexu. Już jest (`idx_mv_voronoi_poz_cell`). Jeśli się skarży — re-create MV:
```sql
DROP INDEX idx_mv_voronoi_poz_cell;
CREATE UNIQUE INDEX idx_mv_voronoi_poz_cell ON mv_voronoi_poz (cell_id);
```

## Skrypty

### `declare: -A: invalid option` (macOS)
macOS ma bash 3.2 domyślnie. Skrypty zostały przepisane na indexed array — sync z `main`:
```bash
git pull origin main
```

### `python3: command not found` w `import_real_data.sh`
Mac: `brew install python` ; Ubuntu: `sudo apt-get install python3` ; Windows WSL: jak Ubuntu.

### `curl: (6) Could not resolve host`
Brak sieci. Skrypt ma cache — jeśli `data/cache/*.json` istnieją, fetch ich nie pobiera ponownie.

## Overpass API

### `HTTP 504 Gateway Timeout`
Query zbyt skomplikowany dla mirrora. Skrypt ma fallback przez 3 endpointy. Jeśli wszystkie failują, spróbuj później (`overpass-api.de` jest najwolniejszy ale najpełniejszy).

### Brakuje znanego SOR (np. Szpital Czerniakowski)
OSM nie ma `emergency=yes` na tym szpitalu. To znane ograniczenie. Możesz dodać go ręcznie:
```sql
INSERT INTO szpitale_sor (nazwa, adres, geom) VALUES (
    'Szpital Czerniakowski',
    'ul. Stępińska 19/25',
    ST_Transform(ST_SetSRID(ST_Point(21.046, 52.214), 4326), 2180)
);
```

## GUS BDL API

### `Nieprawidłowy url`
Sprawdź ID jednostki — powinno być 12-znakowe (TERYT). Patrz `BDL_DZIELNICE` w `scripts/lib/fetch_real_data.py`.

### Brakuje rok 2024+
Variable 72305 ma dane do roku 2024 (aktualizacja roczna). Skrypt domyślnie pobiera 2023; zmień `YEAR = 2023` w fetcherze jeśli potrzebujesz nowszego.

## QGIS

### "Geometry type does not match column type"
Niektóre wyniki `ST_ConcaveHull` mogą zwracać Point/LineString zamiast Polygon (gdy mało wierzchołków). Pliki `qgis/sql_layers/sN_*.sql` mają to obejście (`HAVING COUNT >= 3`).

### Warstwa nie pojawia się po Add Virtual Layer
Sprawdź:
1. Pole "Geometry column" wskazuje na właściwą kolumnę (zwykle `geom`)
2. Pole "Unique identifier" wskazuje na PK (zwykle `id`)
3. SRID = 2180

### Wolne ładowanie warstw
Otwórz **Database → DB Manager** → "Set filter" — ogranicz extent do bbox Warszawy: `630000 490000 680000 525000`.

## pgRouting

### `Function pgr_drivingDistance(...) does not exist`
Extension nie zainstalowane. Sprawdź:
```sql
SELECT extname, extversion FROM pg_extension;
```
Powinieneś zobaczyć `pgrouting`. Jeśli nie:
```sql
CREATE EXTENSION pgrouting;
```

### Brak ścieżki między dwoma węzłami
Graf niespójny (multiple components). Sprawdź:
```sql
SELECT component, COUNT(*) FROM pgr_connectedComponents(
    'SELECT id, source, target, cost FROM drogi_topo'
) GROUP BY component;
```
Jeden zdrowy graf to 1 komponent obejmujący >95% wierzchołków. Wiele małych = corrupt import.
