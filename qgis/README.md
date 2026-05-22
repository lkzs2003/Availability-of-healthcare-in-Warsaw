# Konfiguracja QGIS — podłączenie do PostGIS

## 1. Połączenie z bazą danych

1. Otwórz QGIS 3.x
2. Panel **Browser** → prawym klickiem na **PostGIS** → **New Connection**
3. Wypełnij formularz:

| Pole       | Wartość              |
|------------|----------------------|
| Name       | Warszawa Health      |
| Host       | localhost            |
| Port       | 5432                 |
| Database   | warszawa_health      |
| Username   | postgres             |
| Password   | postgres             |

4. Kliknij **Test Connection** → **OK**

## 2. Warstwy do wczytania

Przeciągnij z panelu Browser lub użyj **Add PostGIS Layers**:

| Tabela               | Typ geometrii     | Styl sugerowany              |
|----------------------|-------------------|------------------------------|
| `dzielnice`          | MultiPolygon      | Wypełnienie przezroczyste, linia gruba |
| `przychodnie_poz`    | Point             | Zielone kółko, r=6           |
| `szpitale_sor`       | Point             | Czerwony krzyż, r=10         |
| `apteki`             | Point             | Niebieskie kółko, r=4        |
| `drogi_topo`         | LineString        | Szara linia, grubość 0.5     |

## 3. Wczytanie wyników scenariuszy jako warstwy SQL

W QGIS możesz dodać warstwę opartą na zapytaniu SQL:

1. **Layer** → **Add Layer** → **Add PostGIS Layers**
2. Kliknij **SQL Query Builder** i wklej wynik z odpowiedniego scenariusza

### Przykład — mapa pustyń medycznych (S1 Q4)

Korzysta z prekomputowanego widoku `mv_pokrycie_poz_1km` (zob. `sql/init/04_materialized_views.sql`):

```sql
SELECT 1 AS id,
       ST_Difference(m.g, p.geom) AS geom
FROM mv_pokrycie_poz_1km p,
     (SELECT ST_Union(geom) AS g FROM dzielnice) m;
```

Ustaw typ geometrii: **Polygon**, SRID: **2180**.

Dla gotowych warstw przygotowanych pod QGIS (uproszczona ścieżka) zobacz pliki
`qgis/sql_layers/s*.sql` — każdy zawiera jedno zapytanie zwracające jedną geometrię.

### Przykład — izochrony SOR (S2 Q4)

Wynik S2 Q4 zawiera kolumnę `izochrona` (geometria) i `strefa` (5/10/15min).
Użyj **Graduated Symbology** po kolumnie `strefa` z 3 kolorami.

### Przykład — siatka czasu dojazdu (S2 Q5)

Wynik zawiera kolumnę `czas_min`. Użyj **Graduated Symbology** → paleta
**RdYlGn** odwrócona (czerwony = długi czas).

## 4. Układ współrzędnych

Wszystkie warstwy są w **EPSG:2180 (PL-1992)**. Upewnij się, że projekt QGIS
używa tego samego CRS (dolny prawy róg ekranu QGIS).

## 5. Drukowanie mapy

**Project** → **New Print Layout** → dodaj:
- Mapę główną (scenariusz)
- Mapę przeglądową (lokalizacja Warszawy w Polsce)
- Legendę, podziałkę, strzałkę północy, tytuł
