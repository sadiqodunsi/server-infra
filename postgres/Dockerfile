FROM postgis/postgis:16-3.5

# pgvector is not bundled in postgis/postgis. The PGDG apt repo is already
# configured on this image, so install the matching PostgreSQL 16 package.
RUN apt-get update \
    && apt-get install -y --no-install-recommends postgresql-16-pgvector \
    && rm -rf /var/lib/apt/lists/*
