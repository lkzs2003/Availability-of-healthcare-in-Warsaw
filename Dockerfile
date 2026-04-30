FROM postgis/postgis:16-3.4

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        postgresql-16-pgrouting \
        osm2pgrouting \
        osmium-tool \
    && rm -rf /var/lib/apt/lists/*

LABEL org.opencontainers.image.description="PostGIS + pgRouting + osmium for Warsaw healthcare accessibility SPDB"
LABEL org.opencontainers.image.source="https://github.com/lkzs2003/Availability-of-healthcare-in-Warsaw"
