# Incident catalogue

These four executable examples preserve the defect classes covered by the acceptance tests.
Each contract names the gate, detector, rule family, and message evidence that must catch the defect.

| id | class | source | example | command | tool | rule | cause |
|---|---|---|---|---|---|---|---|
| n_plus_one | N+1 query | [Validation guide](dogfood-log.md#reproduce-the-checks) | test/fixtures/acceptance/n_plus_one | verify | test_suite | test_failure | USE eager loading |
| unsafe_migration | Unsafe migration | [Validation guide](dogfood-log.md#reproduce-the-checks) | test/fixtures/acceptance/unsafe_migration | verify | test_suite | test_failure | Dangerous operation detected #strong_migrations |
| complexity_creep | Complexity creep | [Validation guide](dogfood-log.md#reproduce-the-checks) | test/fixtures/acceptance/complexity_creep | fast | rubocop | Metrics/* | emitted metric name |
| untested_change | Untested changed code | [Validation guide](dogfood-log.md#reproduce-the-checks) | test/fixtures/acceptance/untested_change | verify | undercover | uncovered_code | changed line range |

## Capture the next escaped class

A new escaped class is accepted only after its written source is recorded, a minimal fixture reproduces
the defect with shipped defaults, and a failing expected-finding assertion names its tool, rule, and
cause signature. Add the catalogue row only with those three pieces so documentation and execution
cannot drift apart.
