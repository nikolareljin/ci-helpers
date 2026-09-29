# python-vuln

A fixture that fails two scans on purpose:

| file | tool | why it fails |
|---|---|---|
| `requirements.txt` | `pip-audit` | `urllib3` and `Jinja2` pinned to versions with published advisories |
| `app/unsafe.py` | `bandit` | `subprocess.call(..., shell=True)`, B602, high severity |

Do not bump the pins and do not fix the module. Both are what make the green
legs mean something: a scanner that finds nothing here is not scanning.

This fixture is scanned by this repository's own weekly Trivy run as well, the
same way `tests/fixtures/go-vuln` is, so its advisories appear in the Security
tab by design.

## Do not write the word `nosec` in `app/unsafe.py`

The first version of this fixture ended the offending line with
`# nosec-free on purpose`. Bandit reads `# nosec` anywhere in a comment as a
suppression marker, so it reported the file clean and the leg asserting a
failure passed for the wrong reason. Measured: with that comment `bandit -q -r
. -ll` exits 0 and reports nothing; without it, `B602`, high severity, exit 1.

## The leg installs PyYAML before it reads the preset

`actions/setup-python` puts its own interpreter first on the PATH, and that one
has no PyYAML -- the runner's system `python3` does. Every other leg in the
suite parses workflow files with the system interpreter and gets away without
the install; the one that sets up Python first does not.
