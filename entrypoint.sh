#!/bin/sh

(
  echo "CREATE TABLE IF NOT EXISTS rates (ts TIMESTAMP PRIMARY KEY, usd DOUBLE, eur DOUBLE, jpy DOUBLE, gbp DOUBLE, cny DOUBLE, chf DOUBLE);"
  echo "CALL quack_serve('quack:0.0.0.0:9494', allow_other_hostname => true, token = '$DUCKDB_TOKEN');"
  tail -f /dev/null
) | duckdb exchange.duckdb &

sleep 2

exec caddy run --config /etc/caddy/Caddyfile
