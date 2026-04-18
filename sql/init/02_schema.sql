-- ============================================================
-- Schema — Dostępność opieki zdrowotnej w Warszawie
-- Układ współrzędnych: EPSG:2180 (PL-1992)
-- ============================================================

-- Districts (18 districts of Warsaw)
CREATE TABLE IF NOT EXISTS dzielnice (
    id               SERIAL PRIMARY KEY,
    nazwa            TEXT NOT NULL UNIQUE,
    powierzchnia_km2 NUMERIC(8, 3),
    geom             GEOMETRY(MULTIPOLYGON, 2180) NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_dzielnice_geom ON dzielnice USING GiST (geom);

-- District demographics
CREATE TABLE IF NOT EXISTS demografia_dzielnice (
    id             SERIAL PRIMARY KEY,
    dzielnica_id   INTEGER NOT NULL REFERENCES dzielnice (id),
    rok            INTEGER NOT NULL DEFAULT 2023,
    ludnosc        INTEGER NOT NULL,
    gestosc_os_km2 NUMERIC(10, 2),
    UNIQUE (dzielnica_id, rok)
);

-- Primary healthcare clinics (POZ — Podstawowa Opieka Zdrowotna)
CREATE TABLE IF NOT EXISTS przychodnie_poz (
    id        SERIAL PRIMARY KEY,
    nazwa     TEXT NOT NULL,
    adres     TEXT,
    nr_rpwdl  TEXT,
    geom      GEOMETRY(POINT, 2180) NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_przychodnie_poz_geom ON przychodnie_poz USING GiST (geom);
CREATE INDEX IF NOT EXISTS idx_przychodnie_poz_rpwdl ON przychodnie_poz (nr_rpwdl);

-- Hospitals with emergency rooms (SOR — Szpitalny Oddział Ratunkowy)
CREATE TABLE IF NOT EXISTS szpitale_sor (
    id    SERIAL PRIMARY KEY,
    nazwa TEXT NOT NULL,
    adres TEXT,
    geom  GEOMETRY(POINT, 2180) NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_szpitale_sor_geom ON szpitale_sor USING GiST (geom);

-- Pharmacies
CREATE TABLE IF NOT EXISTS apteki (
    id    SERIAL PRIMARY KEY,
    nazwa TEXT NOT NULL,
    adres TEXT,
    geom  GEOMETRY(POINT, 2180) NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_apteki_geom ON apteki USING GiST (geom);

-- Road network vertices (nodes)
CREATE TABLE IF NOT EXISTS drogi_vertices (
    id   BIGINT PRIMARY KEY,
    geom GEOMETRY(POINT, 2180)
);

CREATE INDEX IF NOT EXISTS idx_drogi_vertices_geom ON drogi_vertices USING GiST (geom);

-- Road network edges (topology)
CREATE TABLE IF NOT EXISTS drogi_topo (
    id           SERIAL PRIMARY KEY,
    source       INTEGER,
    target       INTEGER,
    cost         NUMERIC,          -- metres (length of segment)
    reverse_cost NUMERIC,          -- same for bidirectional roads
    geom         GEOMETRY(LINESTRING, 2180)
);

CREATE INDEX IF NOT EXISTS idx_drogi_topo_source  ON drogi_topo (source);
CREATE INDEX IF NOT EXISTS idx_drogi_topo_target  ON drogi_topo (target);
CREATE INDEX IF NOT EXISTS idx_drogi_topo_geom    ON drogi_topo USING GiST (geom);
