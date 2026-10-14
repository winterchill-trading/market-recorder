# examples: market-recorder configs

- `sims.sexp`: records the three simulators. The CI `e2e-sims` job and `e2e-sims.sh` use it.
- `mainnet-all.sexp`: all venues against real endpoints. Do not run it without being asked.

Rules:

- Every example must pass `market-recorder check-config`; a test checks each one.
- Configs hold no credentials.
