# Contract examples

Every file here is a **contract example, not live data**. The values are invented to
illustrate the response shapes; they do not describe any real product, deployment or person.

Each file carries an `_example_notice` property saying the same thing. A real companion
never sends `_example_notice`; clients ignore unknown properties, so the examples still
parse with the same code as real responses.

| File | Endpoint | Schema |
| --- | --- | --- |
| `status.example.json` | `GET /_forgedeck/v1/status` | `../status.schema.json` |
| `status-mixed-revisions.example.json` | `GET /_forgedeck/v1/status` with the optional `instances`, `booted_at`, build fields | `../status.schema.json` |
| `manifest.example.json` | `GET /_forgedeck/v1/manifest` | `../manifest.schema.json` |
| `metrics.example.json` | `GET /_forgedeck/v1/metrics?window=24h` | `../metrics.schema.json` |
| `leads.example.json` | `GET /_forgedeck/v1/leads` (default: no contact fields) | `../events.schema.json` |
| `leads-masked-label.example.json` | `GET /_forgedeck/v1/leads` with the opt-in masked label | `../events.schema.json` |
| `events.example.json` | `GET /_forgedeck/v1/events` | `../events.schema.json` |
| `error.example.json` | any non-2xx response | `../error.schema.json` |

The Python test suite (`python/tests/test_contract.py`) validates every example against its schema.
