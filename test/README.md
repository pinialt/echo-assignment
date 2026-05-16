# test/

Automated HTTP compatibility test (Go or Python) — proves the rebuilt image
behaves like `nginx:1.25-bookworm` for a representative set of scenarios.

Behavior:

1. Boot `nginx:1.25-bookworm` and our image as separate containers.
2. Issue the same set of HTTP requests against each:
   - `GET /` on the default config
   - request against a custom config mounted in
   - large request body
   - malformed request
   - (add more as needed)
3. Assert response **status + headers + body** match.
4. Exit non-zero on any mismatch.

What "working correctly" means and the exact scenario list lives here once
the test is implemented.

Entry point: `make test` from the repo root.
