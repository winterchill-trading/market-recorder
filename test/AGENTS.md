# test: market-recorder tests

Expect and integration tests. Among them: every example config is checked, 100 minute rolls must keep
the descriptor count flat, a local websocket server checks that Binance symbols subscribe once per
connection, and the rotation tests use a synthetic clock.

Rules:

- Do not add a test that needs real venues; the simulators and local servers are the test targets.
- Use `Time_source` for rotation, not sleeps.
- Promote expect output with `dune promote` only after reading the diff.
