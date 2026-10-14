# .github: market-recorder CI

`workflows/ci.yml` has three groups: build and tests (with shellcheck and `libsecp256k1-dev`), the
`e2e-sims` job (20 seconds against the simulators, with an artifact upload), and the alert rules job.

Rules:

- Keep the pin list in dependency order, matching `../specs/repos/market-recorder.md`.
- The `e2e-sims` job checks out the simulators from main; a simulator break fails this repository.
- To check a run: `gh run list --limit 1`, then at most one `gh run watch <id> --exit-status`.
