# deploy: monitoring rules

`prometheus/alerts.yml` holds the alert rules, including the parse-error, reconnect and health rules
built on the client statistics. `alerts_test.yml` is its unit test; CI runs it in the alert rules job.

Rules:

- Change a rule and its test in the same commit.
- A new alert names the metric it reads; the metric must be exported by the `Metrics` module.
