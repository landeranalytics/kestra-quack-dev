FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*

ENV DUCKDB_VERSION=1.5.5
RUN curl https://install.duckdb.org | bash

RUN curl -L https://github.com/caddyserver/caddy/releases/download/v2.8.4/caddy_2.8.4_linux_amd64.tar.gz \
    | tar xz -C /usr/local/bin caddy

ENV PATH="/root/.duckdb/cli/latest:${PATH}"

WORKDIR /data

EXPOSE 8080

COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
