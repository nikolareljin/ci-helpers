# iac-misconfig

A pair, because one alone proves nothing:

| directory | `trivy --scanners misconfig` at CRITICAL,HIGH |
|---|---|
| `bad/` | exit 1 -- `DS-0002`, "Image user should not be 'root'" |
| `good/` | exit 0 |

Measured on 2026-09-29. Both also trip `DS-0026` ("No HEALTHCHECK defined") at
LOW, which is below the severity the legs scan at -- `good/` sets a
HEALTHCHECK anyway so the difference between the two is one rule, not two.

Do not fix `bad/`. A fixture that stops failing turns a leg green for the
wrong reason, and nothing says so.
