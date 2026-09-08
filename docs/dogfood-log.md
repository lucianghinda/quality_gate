# Validation guide

The public acceptance fixtures exercise four representative incident classes with
shipped defaults: N+1 queries, unsafe migrations, complexity creep, and untested
changed code. The [incident catalogue](incidents.md) maps each class to its fixture,
command, and expected finding. These fixtures test detection behavior; they do not
establish compatibility with every application or dependency version.

## Reproduce the checks

After installing development dependencies, run the executable incident contracts:

```sh
bundle exec ruby -Itest test/acceptance/incident_catalog_test.rb
```

Run the complete test suite and aggregate coverage checks with:

```sh
COVERAGE=1 bundle exec rake test
```

Latency checks are opt-in because load and runtime configuration affect results:

```sh
QUALITY_GATE_ACCEPTANCE_TIMING=1 bundle exec ruby -Itest test/acceptance/latency_test.rb
```

The fixture budgets are below 2 seconds for a warm file-scoped `fast` run and below
3 seconds for the installed hook round trip. These are test targets, not measured
release guarantees. A skipped timing check provides no latency evidence.

## Interpretation and limits

A clean gate means its configured tools completed without reportable findings.
A timeout, unavailable tool, skipped comparison, or unsupported dependency is not
proof of clean application behavior. Inspect findings and warnings alongside exit
status. The Stop hook can fail open when verification is unavailable; that outcome
must not be counted as successful verification.

Application initialization and third-party compatibility can prevent installation
or checks from completing. Validate the generator, optional initializers, and all
configured gates in the target application. Fixture results do not guarantee
production compatibility, performance, reduced review time, or agent adoption.

The public release includes reproducible fixture contracts rather than private
application records. No current production cohort measurements are claimed.
