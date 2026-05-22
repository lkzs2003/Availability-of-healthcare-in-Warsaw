-- ============================================================
-- Seed data — synthetic dataset for testing all 6 scenarios
-- Real data should be imported via scripts/import_*.sh
-- Coordinates in WGS84 are transformed to EPSG:2180 on insert
-- ============================================================

-- Helper: transform WGS84 point to EPSG:2180
CREATE OR REPLACE FUNCTION f_pt(lon FLOAT8, lat FLOAT8)
RETURNS GEOMETRY AS $$
    SELECT ST_Transform(ST_SetSRID(ST_Point(lon, lat), 4326), 2180)
$$ LANGUAGE sql IMMUTABLE;


-- -----------------------------------------------------------
-- 1. Districts — NON-OVERLAPPING Voronoi tessellation
--    Built from district centroids, clipped to a simplified
--    polygon of Warsaw's administrative boundary.
--    Real PRG/Geoportal boundaries should replace these in production.
-- -----------------------------------------------------------
WITH
warszawa_boundary AS (
    -- Simplified Warsaw boundary (10-vertex polygon in WGS84)
    SELECT ST_Transform(
        ST_SetSRID(ST_GeomFromText(
            'POLYGON((
                20.852 52.098, 21.050 52.095, 21.271 52.173,
                21.271 52.298, 21.225 52.373, 21.100 52.374,
                20.953 52.368, 20.852 52.330, 20.852 52.210,
                20.852 52.098
            ))'
        ), 4326), 2180) AS geom
),
centroids (nazwa, lon, lat) AS (VALUES
    ('Bemowo',         20.936, 52.248),
    ('Białołęka',      21.028, 52.320),
    ('Bielany',        20.966, 52.289),
    ('Mokotów',        21.013, 52.197),
    ('Ochota',         20.982, 52.218),
    ('Praga-Południe', 21.064, 52.228),
    ('Praga-Północ',   21.036, 52.251),
    ('Rembertów',      21.157, 52.248),
    ('Śródmieście',    21.004, 52.232),
    ('Targówek',       21.059, 52.281),
    ('Ursus',          20.889, 52.196),
    ('Ursynów',        21.034, 52.152),
    ('Wawer',          21.134, 52.184),
    ('Wesoła',         21.201, 52.232),
    ('Wilanów',        21.086, 52.165),
    ('Włochy',         20.929, 52.196),
    ('Wola',           20.977, 52.234),
    ('Żoliborz',       20.987, 52.267)
),
centroid_pts AS (
    SELECT nazwa, f_pt(lon, lat) AS geom FROM centroids
),
voronoi_raw AS (
    SELECT (ST_Dump(ST_VoronoiPolygons(
        ST_Collect(cp.geom), 0.0, (SELECT geom FROM warszawa_boundary)
    ))).geom AS cell
    FROM centroid_pts cp
),
matched_raw AS (
    -- Match each centroid to its raw unclipped Voronoi cell first (stable 1-to-1 matching)
    SELECT cp.nazwa, vr.cell
    FROM centroid_pts cp
    JOIN voronoi_raw vr ON ST_Contains(vr.cell, cp.geom)
)
INSERT INTO dzielnice (nazwa, powierzchnia_km2, geom)
SELECT mr.nazwa,
       ROUND((ST_Area(ST_Intersection(mr.cell, wb.geom)) / 1e6)::NUMERIC, 3) AS powierzchnia_km2,
       ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_Intersection(mr.cell, wb.geom)), 3)) AS geom
FROM matched_raw mr, warszawa_boundary wb;


-- -----------------------------------------------------------
-- 2. District demographics (GUS BDL 2023 — real values)
--    Density uses the synthetic Voronoi area, so it's indicative.
-- -----------------------------------------------------------
INSERT INTO demografia_dzielnice (dzielnica_id, rok, ludnosc, gestosc_os_km2)
SELECT d.id, 2023, v.ludnosc, ROUND(v.ludnosc / d.powierzchnia_km2, 2)
FROM dzielnice d
JOIN (VALUES
    ('Bemowo',         126876),
    ('Białołęka',      128982),
    ('Bielany',        136464),
    ('Mokotów',        221576),
    ('Ochota',          84524),
    ('Praga-Południe', 178467),
    ('Praga-Północ',    73618),
    ('Rembertów',       24073),
    ('Śródmieście',    106483),
    ('Targówek',       120879),
    ('Ursus',           69028),
    ('Ursynów',        157488),
    ('Wawer',           80459),
    ('Wesoła',          23844),
    ('Wilanów',         41706),
    ('Włochy',          56793),
    ('Wola',           141441),
    ('Żoliborz',        74453)
) AS v(nazwa, ludnosc) ON d.nazwa = v.nazwa;


-- -----------------------------------------------------------
-- 3. SOR Hospitals (5 main emergency hospitals in Warsaw)
-- -----------------------------------------------------------
INSERT INTO szpitale_sor (nazwa, adres, geom) VALUES
('Szpital Bielański',          'ul. Cegłowska 80, Bielany',         f_pt(20.964, 52.284)),
('Szpital Wolski im. dr A. Gostyńskiej', 'ul. Kasprzaka 17, Wola', f_pt(20.952, 52.237)),
('Szpital Bródnowski',         'ul. Kondratowicza 8, Targówek',     f_pt(21.063, 52.268)),
('Szpital Praski',             'al. Solidarności 67, Praga-Północ', f_pt(21.047, 52.250)),
('Szpital Południowy',         'ul. Rotmistrza Witolda Pileckiego 99, Ursynów', f_pt(21.037, 52.138));


-- -----------------------------------------------------------
-- 4. Primary healthcare clinics (POZ) — 25 clinics
-- -----------------------------------------------------------
INSERT INTO przychodnie_poz (nazwa, adres, nr_rpwdl, geom) VALUES
('NZOZ Medica Śródmieście',    'ul. Marszałkowska 34',                'W-000001', f_pt(21.015, 52.230)),
('CM LUX MED Mokotów',         'ul. Puławska 120',                    'W-000002', f_pt(21.005, 52.205)),
('Przychodnia Bielany',        'ul. Przy Agorze 2',                   'W-000003', f_pt(20.950, 52.285)),
('NZOZ Wola Centrum',          'ul. Wolska 68',                       'W-000004', f_pt(20.968, 52.242)),
('CM Ursynów',                 'al. KEN 98',                          'W-000005', f_pt(21.038, 52.155)),
('Przychodnia Praga-Południe', 'ul. Grochowska 271',                  'W-000006', f_pt(21.075, 52.228)),
('NZOZ Targówek Med',          'ul. Radzymińska 116',                 'W-000007', f_pt(21.065, 52.278)),
('CM Białołęka',               'ul. Ostródzka 13',                    'W-000008', f_pt(21.045, 52.325)),
('Przychodnia Bemowo',         'ul. Powstańców Śląskich 104',         'W-000009', f_pt(20.920, 52.250)),
('NZOZ Żoliborz Medyk',        'ul. Tucholska 2',                     'W-000010', f_pt(20.995, 52.265)),
('CM Ochota',                  'ul. Grójecka 65',                     'W-000011', f_pt(20.975, 52.220)),
('Przychodnia Wilanów',        'ul. Klimczaka 14',                    'W-000012', f_pt(21.090, 52.160)),
('NZOZ Wawer',                 'ul. Żegańska 1',                      'W-000013', f_pt(21.140, 52.185)),
('CM Ursus',                   'ul. Plutonu Torpedy 7',               'W-000014', f_pt(20.885, 52.200)),
('Przychodnia Włochy',         'ul. Hynka 4',                         'W-000015', f_pt(20.935, 52.195)),
('NZOZ Wesoła',                'ul. 1 Praskiego Pułku 21',            'W-000016', f_pt(21.205, 52.235)),
('CM Rembertów',               'ul. Plutonu Torpedy 2',               'W-000017', f_pt(21.160, 52.250)),
('NZOZ Praga-Północ',          'ul. Brzeska 12',                      'W-000018', f_pt(21.040, 52.255)),
('CM Śródmieście 2',           'ul. Kredytowa 8',                     'W-000019', f_pt(20.995, 52.240)),
('Przychodnia Mokotów 2',      'ul. Domaniewska 32',                  'W-000020', f_pt(21.020, 52.193)),
('NZOZ Bielany 2',             'ul. Wrzeciono 47',                    'W-000021', f_pt(20.972, 52.296)),
('CM Wola 2',                  'ul. Leszno 127',                      'W-000022', f_pt(20.960, 52.230)),
('Przychodnia Ursynów 2',      'ul. Belgradzka 4',                    'W-000023', f_pt(21.025, 52.148)),
('NZOZ Białołęka 2',           'ul. Mehoffera 72',                    'W-000024', f_pt(21.060, 52.318)),
('CM Bemowo 2',                'ul. Górczewska 224',                  'W-000025', f_pt(20.945, 52.255));


-- -----------------------------------------------------------
-- 5. Pharmacies — 40 spread across Warsaw
-- -----------------------------------------------------------
INSERT INTO apteki (nazwa, adres, geom) VALUES
('Apteka Dbam o Zdrowie',          'ul. Marszałkowska 1',        f_pt(21.012, 52.231)),
('Apteka DOZ',                     'ul. Puławska 2',             f_pt(21.006, 52.208)),
('Apteka Gemini',                  'ul. Wolska 10',              f_pt(20.971, 52.243)),
('Apteka Melissa',                 'ul. Grochowska 50',          f_pt(21.071, 52.227)),
('Apteka Zdrowie',                 'ul. Bielańska 3',            f_pt(20.993, 52.247)),
('Apteka Dr Max',                  'al. KEN 12',                 f_pt(21.040, 52.158)),
('Apteka Cefarm',                  'ul. Targowa 22',             f_pt(21.050, 52.249)),
('Apteka SuperPharm',              'ul. Kondratowicza 1',        f_pt(21.060, 52.270)),
('Apteka Synoptis',                'ul. Cegłowska 5',            f_pt(20.968, 52.287)),
('Apteka Ziko',                    'ul. Przy Agorze 5',          f_pt(20.952, 52.284)),
('Apteka Dbam o Zdrowie 2',        'ul. Grójecka 10',            f_pt(20.978, 52.221)),
('Apteka DOZ 2',                   'ul. Hynka 2',                f_pt(20.938, 52.196)),
('Apteka Gemini 2',                'ul. Ostródzka 2',            f_pt(21.048, 52.326)),
('Apteka Melissa 2',               'ul. Mehoffera 5',            f_pt(21.061, 52.319)),
('Apteka Zdrowie 2',               'ul. Mehoffera 30',           f_pt(21.055, 52.314)),
('Apteka Dr Max 2',                'ul. Tucholska 10',           f_pt(20.997, 52.267)),
('Apteka Cefarm 2',                'ul. Wrzeciono 10',           f_pt(20.974, 52.298)),
('Apteka SuperPharm 2',            'ul. Domaniewska 5',          f_pt(21.018, 52.194)),
('Apteka Synoptis 2',              'ul. Klimczaka 2',            f_pt(21.088, 52.161)),
('Apteka Ziko 2',                  'ul. Belgradzka 10',          f_pt(21.027, 52.149)),
('Apteka Nonstop',                 'ul. Kredytowa 2',            f_pt(20.997, 52.241)),
('Apteka Centrum',                 'ul. Leszno 50',              f_pt(20.961, 52.232)),
('Apteka Pharmacia',               'ul. Górczewska 50',          f_pt(20.942, 52.252)),
('Apteka Polmed',                  'ul. Powstańców Śląskich 20', f_pt(20.923, 52.251)),
('Apteka Remedium',                'ul. Radzymińska 20',         f_pt(21.063, 52.279)),
('Apteka Vademecum',               'ul. Brzeska 5',              f_pt(21.041, 52.256)),
('Apteka Na Zdrowie',              'ul. Żegańska 5',             f_pt(21.142, 52.186)),
('Apteka Vita',                    'ul. Plutonu Torpedy 5',      f_pt(20.887, 52.201)),
('Apteka Eskulap',                 'ul. 1 Praskiego Pułku 5',    f_pt(21.208, 52.236)),
('Apteka Dbam o Zdrowie 3',        'ul. Wolska 120',             f_pt(20.964, 52.236)),
('Apteka DOZ 3',                   'ul. Marszałkowska 120',      f_pt(21.001, 52.222)),
('Apteka Gemini 3',                'ul. Puławska 180',           f_pt(21.010, 52.187)),
('Apteka Melissa 3',               'ul. Grochowska 150',         f_pt(21.079, 52.224)),
('Apteka Zdrowie 3',               'ul. Solidarności 100',       f_pt(21.044, 52.251)),
('Apteka Dr Max 3',                'ul. Roentgena 5',            f_pt(21.037, 52.147)),
('Apteka Cefarm 3',                'ul. Kasprzaka 2',            f_pt(20.953, 52.238)),
('Apteka SuperPharm 3',            'ul. Szosa Lubelska 5',       f_pt(21.138, 52.183)),
('Apteka Nonstop 2',               'ul. Nowogrodzka 11',         f_pt(21.009, 52.228)),
('Apteka Centrum 2',               'ul. Złota 59',               f_pt(21.007, 52.232)),
('Apteka Pharmacia 2',             'ul. Sienna 73',              f_pt(21.001, 52.229));


-- -----------------------------------------------------------
-- 6. Road network — synthetic 5 km grid covering Warsaw
--    Cost = segment length in metres; 5000 m at 50 km/h ~ 6 min
--    Node ID: row * 11 + col + 1  (col in 0..10, row in 0..7)
--    BBOX origin (x0, y0) is read from warszawa_bbox (single source of truth).
-- -----------------------------------------------------------
DO $$
DECLARE
    step   CONSTANT NUMERIC := 5000;
    nx     CONSTANT INTEGER := 11;
    ny     CONSTANT INTEGER := 8;
    x0     NUMERIC;
    y0     NUMERIC;
    eid    BIGINT := 1;
    r      INTEGER;
    c      INTEGER;
    src_id BIGINT;
    tgt_id BIGINT;
    x1     NUMERIC; y1 NUMERIC;
    x2     NUMERIC; y2 NUMERIC;
BEGIN
    SELECT xmin, ymin INTO x0, y0 FROM warszawa_bbox;
    -- Vertices
    FOR r IN 0..(ny - 1) LOOP
        FOR c IN 0..(nx - 1) LOOP
            INSERT INTO drogi_vertices (id, geom)
            VALUES (
                r * nx + c + 1,
                ST_SetSRID(ST_Point(x0 + c * step, y0 + r * step), 2180)
            );
        END LOOP;
    END LOOP;

    -- Horizontal edges (west–east)
    FOR r IN 0..(ny - 1) LOOP
        FOR c IN 0..(nx - 2) LOOP
            src_id := r * nx + c + 1;
            tgt_id := r * nx + c + 2;
            x1 := x0 + c * step;       y1 := y0 + r * step;
            x2 := x0 + (c + 1) * step; y2 := y1;
            INSERT INTO drogi_topo (id, source, target, cost, reverse_cost, geom)
            VALUES (eid, src_id, tgt_id, step, step,
                ST_SetSRID(ST_MakeLine(ST_Point(x1, y1), ST_Point(x2, y2)), 2180));
            eid := eid + 1;
        END LOOP;
    END LOOP;

    -- Vertical edges (south–north)
    FOR r IN 0..(ny - 2) LOOP
        FOR c IN 0..(nx - 1) LOOP
            src_id := r * nx + c + 1;
            tgt_id := (r + 1) * nx + c + 1;
            x1 := x0 + c * step; y1 := y0 + r * step;
            x2 := x1;            y2 := y0 + (r + 1) * step;
            INSERT INTO drogi_topo (id, source, target, cost, reverse_cost, geom)
            VALUES (eid, src_id, tgt_id, step, step,
                ST_SetSRID(ST_MakeLine(ST_Point(x1, y1), ST_Point(x2, y2)), 2180));
            eid := eid + 1;
        END LOOP;
    END LOOP;
END $$;

-- Re-sync the BIGSERIAL sequence for drogi_topo (manual id inserts don't bump it)
SELECT setval(
    pg_get_serial_sequence('drogi_topo', 'id'),
    (SELECT MAX(id) FROM drogi_topo)
);

-- Clean up helper function (not needed beyond init)
DROP FUNCTION f_pt(FLOAT8, FLOAT8);

-- Refresh planner statistics for EXPLAIN ANALYZE in S5 to be accurate
ANALYZE dzielnice;
ANALYZE demografia_dzielnice;
ANALYZE przychodnie_poz;
ANALYZE szpitale_sor;
ANALYZE apteki;
ANALYZE drogi_vertices;
ANALYZE drogi_topo;
