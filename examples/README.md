# Examples

Standalone exploratory notes from early quack experimentation, kept for
reference. These are unrelated to the Kestra exchange-rate demo documented in
the top-level [README](../README.md) — they predate it and talk to quack
directly (`localhost:8080`) rather than through Kestra.

- `quack.sql` — ad hoc queries exploring `ATTACH` vs `quack_query()`,
  including writing a local CSV (`mtcars.csv`) to a remote table.
- `retach.sql` — the detach/reattach snippet `quack.sql` references via
  `.read retach.sql`.
- `mtcars.csv` — sample data used by `quack.sql`.
