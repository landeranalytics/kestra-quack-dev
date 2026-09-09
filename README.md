# Quack + Kestra Exchange Rate Demo

This repository demonstrates **Kestra** orchestrating parallel workflows that write into a **DuckDB Quack server** — DuckDB's client/server protocol — using the real `duckdb` CLI rather than a JDBC driver.

## Architecture

- **DuckDB Quack Server** (`localhost:8080`): a persistent DuckDB database (`exchange.duckdb`) with a `rates` table. `quack_serve()` binds internally on port `9494`; **Caddy** reverse-proxies external port `8080` to it.
- **Kestra** (`localhost:8085`): a workflow orchestrator running two flows:
  - **Parent** (`fetch_exchange_rates`): pre-creates a row for the current timestamp, then fans out to 5 parallel `convert` subflows (EUR, JPY, GBP, CNY, CHF). Cleans up the row if any child fails.
  - **Child** (`convert`): fetches one currency's rate from the Frankfurter API and writes it into the pre-created row.
- **PostgreSQL**: Kestra's metadata backend.
- **`quack-network`**: a named Docker network joining `postgres`, `duckdb`, and `kestra`. Kestra's Docker task runner attaches each flow-spawned container to this network by name so it can reach the `duckdb` service directly.

Each Kestra task that talks to quack runs the official **`duckdb/duckdb`** Docker image directly (via Kestra's `shell.Commands` task + Docker task runner), not Kestra's `plugin-jdbc-duckdb` — the JDBC driver could not reliably prepare statements against the quack wire protocol. `interpreter: ["/duckdb", "-c"]` is used because that image has no shell.

## Running the Demo

### Prerequisites

- Docker & Docker Compose
- A `.env` file (copy from `.env.example`)

### Step 1: Create `.env`

```bash
cp .env.example .env
```

`.env` needs **two keys that must decode to the same value**:

```bash
# Plain value — read by docker-compose to configure the quack server's auth token
DUCKDB_TOKEN=token

# Same value, base64-encoded — read by Kestra (env_file) and exposed to flows as {{ secret('DUCKDB_TOKEN') }}
SECRET_DUCKDB_TOKEN=dG9rZW4=
```

Generate the base64 value with `echo -n "token" | base64`. These two keys are consumed by two completely different mechanisms (docker-compose variable substitution vs. Kestra's secret store), so if you change the token, update both.

### Step 2: Start Services

```bash
docker compose up -d --build
```

```bash
docker compose ps
```

You should see `postgres` (healthy), `duckdb`, and `kestra` all running, plus a `quack-network` Docker network joining them (`docker network ls`).

### Step 3: Verify the Database Schema

```bash
docker run --rm --network quack-network --entrypoint /duckdb duckdb/duckdb:latest -c "
INSTALL quack;
LOAD quack;
ATTACH 'quack:duckdb:8080' AS remote (TOKEN 'token', DISABLE_SSL true);
FROM remote.rates;
"
```

Should return an empty table with columns `ts`, `usd`, `eur`, `jpy`, `gbp`, `cny`, `chf`.

### Step 4: Run the Workflow

1. Open Kestra UI at `http://localhost:8085` (basic auth: `admin@kestra.io` / `Admin1234`, set in `docker-compose.yml` — change these before exposing the UI beyond localhost)
2. Find `quack.demo.fetch_exchange_rates` and click **Execute**
3. Watch it pre-create a row, then fan out to 5 parallel `convert` subflows

Or trigger it via API:

```bash
curl -s -X POST -u "<user>:<pass>" \
  "http://localhost:8085/api/v1/main/executions/trigger/quack.demo/fetch_exchange_rates"
```

### Step 5: Verify Data Was Written

```bash
docker run --rm --network quack-network --entrypoint /duckdb duckdb/duckdb:latest -c "
INSTALL quack;
LOAD quack;
ATTACH 'quack:duckdb:8080' AS remote (TOKEN 'token', DISABLE_SSL true);
FROM remote.rates ORDER BY ts DESC LIMIT 1;
"
```

OR

```bash
docker compose down
duckdb data/exchange.duckdb -c "SELECT * FROM rates;"
```

Should show one row with `usd = 1.0` and live rates for all 5 currencies.

### Step 6 (Optional): Run Again

Each run computes a fresh timestamp, so re-running inserts a new row rather than colliding with the previous one. The [Frankfurter API](https://frankfurter.dev/) only updates its rates once a day, so back-to-back runs will show identical currency values — only the `ts` column will differ between rows.

## Technical Details

### Flow: `fetch_exchange_rates` (Parent)

1. `set_ts` — computes one shared timestamp (`io.kestra.plugin.core.debug.Return`), reused by every child so they all write to the same row.
2. `create_row` — connects via `ATTACH` and does a plain `INSERT` to create the row (`ts`, `usd = 1.0`, all currency columns `NULL`) *before* fan-out.
3. `currencies` — a `ForEach` with `concurrencyLimit: 0` running 5 `convert` subflows in true parallel.
4. `errors` — if any child fails, deletes the row for that `ts` via `quack_query`, so a partially-written row never survives a failed run.

### Flow: `convert` (Child)

Given `currency` and `ts`:
1. Fetches the rate **locally** (inside the client container) with `read_json_auto()` against the Frankfurter API, storing the result in a DuckDB session variable (`SET VARIABLE rate = ...`).
2. Writes it with `CALL quack_query('quack:duckdb:8080', 'UPDATE rates SET <currency> = ' || getvariable('rate') || ' WHERE ts = ...', token := ..., disable_ssl := true)`.

Fetching the JSON client-side (rather than embedding `read_json_auto(...)` inside the `quack_query` SQL string) keeps the RPC statement short and avoids nested-quote SQL-in-SQL escaping.

### Why pre-create the row, and why `UPDATE` instead of upsert?

DuckDB uses **optimistic concurrency control**: concurrent transactions that touch the same row cause a conflict, by design ([docs](https://duckdb.org/docs/current/connect/concurrency)). With 5 children racing to `INSERT ... ON CONFLICT` the very first row for a brand-new `ts`, two of them can each see "no row yet" and both attempt the initial insert — one wins, one gets a duplicate-key error, since `ON CONFLICT` doesn't protect against that specific race.

The fix: the **parent** creates the row once, synchronously, before fan-out. Each child then only ever `UPDATE`s a single column of an already-existing row — no insert race.

Separately, quack's remote catalog only supports plain `INSERT` through `ATTACH`:
- `UPDATE` via `ATTACH` fails with `Binder Error: Can only update base table`
- `INSERT ... ON CONFLICT` via `ATTACH` fails with `Not implemented Error: GetStorageInfo not implemented yet`

So the child's `UPDATE` goes through `quack_query()` (a stateless RPC call) instead of `ATTACH`, while the parent's plain `INSERT` uses `ATTACH` directly.

## Environment Variables

| Variable | File | Purpose |
|---|---|---|
| `DUCKDB_TOKEN` | `.env` (plain) | Read by docker-compose, sets the quack server's actual auth token |
| `SECRET_DUCKDB_TOKEN` | `.env` (base64) | Read by Kestra's `env_file`, exposed to flows as `{{ secret('DUCKDB_TOKEN') }}` |

These must decode to the same value — see Step 1.

## Volumes & Network

- `./data:/data` — bind-mounted, persists `exchange.duckdb` across container restarts (host-visible at `./data/exchange.duckdb`, but see Troubleshooting — you can't open it directly while the server is running)
- `postgres-data` — Kestra's Postgres backend
- `kestra-data` — Kestra's internal storage
- `./flows:/workflows` — flow definitions, auto-synced via Kestra's file-watcher
- `quack-network` — named Docker network; referenced explicitly by flows' `taskRunner.networkMode` so dynamically-spawned task containers can reach the `duckdb` service by name

## Troubleshooting

**Flows don't appear / don't pick up edits in Kestra UI?**
- The file-watcher polls `/workflows` every ~5-10 seconds
- Check `docker compose logs kestra | grep -i flow`
- Force it via the API: `curl -X PUT -u <user>:<pass> -H "Content-Type: application/x-yaml" --data-binary @flows/<file>.yml http://localhost:8085/api/v1/main/flows/quack.demo/<flow_id>`

**`Serialization Error: Failed to deserialize: not enough data in buffer to fulfill read request`?**
This was the symptom of a now-fixed Caddy bug: the old `Caddyfile` matched only `http://localhost:8080` as a site block, so any request with a different `Host` header (e.g. from another container using the `duckdb` service name) didn't match and got a broken/incomplete proxied response. The `Caddyfile` now uses `:8080` to match any host. If you see this again, check that `Caddyfile` still uses `:8080`, not a hostname-qualified address.

**`Not implemented Error: GetStorageInfo not implemented yet` or `Binder Error: Can only update base table`?**
Real, current limitations of quack's remote-catalog (`ATTACH`) interface — not bugs. Use `quack_query()` (a stateless RPC call) for `UPDATE` or upsert-style writes instead; `ATTACH` only reliably supports plain `INSERT`/`SELECT`.

**`Invalid Input Error: Duplicate key ... violates primary key constraint`?**
A concurrent-write race (see "Why pre-create the row" above) — DuckDB's optimistic concurrency control, not a Kestra or quack bug. Don't add a naive retry on the child; the actual fix is serializing the first insert (already done by `create_row` in the parent).

**Can't open `data/exchange.duckdb` directly with a local `duckdb` CLI?**
Expected — DuckDB only allows one process to hold a database file open at a time, and the running `duckdb` container holds it continuously via `quack_serve()`. Use quack (as in the verification steps above) to inspect data while the stack is running, or `docker compose stop duckdb` first if you need raw file access.

**Auth errors from flows?**
Confirm `DUCKDB_TOKEN` (plain) and `SECRET_DUCKDB_TOKEN` (base64) in `.env` decode to the same value, and that you recreated the `duckdb` container after changing `.env` (`docker compose up -d duckdb`) — docker-compose only re-reads `.env` for variable substitution on container (re)creation.

## Examples

[`examples/`](examples/) has standalone exploratory quack notes unrelated to
this demo — see its README for details.

## References

- [Kestra Docs](https://kestra.io/docs)
- [DuckDB Quack Protocol](https://duckdb.org/docs/current/quack/overview)
- [DuckDB Concurrency](https://duckdb.org/docs/current/connect/concurrency)
- [Frankfurter API](https://frankfurter.dev/)
