#!/usr/bin/env bash
# SCRIPT: docs_site_paths_test.sh
# DESCRIPTION: every input mkdocs reads (mkdocs.yml, docs_dir, theme.custom_dir,
#              hooks, requirements-docs.txt) is in the on.<event>.paths filter
#              of docs-site.yml and docs-site-pr.yml, so a change to any of
#              them builds and deploys the site. Needs PyYAML.
# USAGE: bash tests/docs_site_paths_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$root" <<'PY'
import sys
from pathlib import Path

import yaml

root = Path(sys.argv[1])


class Loader(yaml.SafeLoader):
    pass


# mkdocs.yml may carry !!python/name or !ENV tags; their values do not matter here.
Loader.add_multi_constructor("", lambda loader, suffix, node: None)
Loader.add_multi_constructor("tag:yaml.org,2002:python/", lambda loader, suffix, node: None)

cfg = yaml.load((root / "mkdocs.yml").read_text(), Loader=Loader)
theme = cfg.get("theme") or {}

needed = ["mkdocs.yml", "requirements-docs.txt", f"{cfg.get('docs_dir', 'docs')}/**"]
if isinstance(theme, dict) and theme.get("custom_dir"):
    needed.append(f"{theme['custom_dir'].rstrip('/')}/**")
for hook in cfg.get("hooks") or []:
    needed.append(hook)

fail = 0
for wf, event in (("docs-site.yml", "push"), ("docs-site-pr.yml", "pull_request")):
    doc = yaml.safe_load((root / ".github/workflows" / wf).read_text())
    on = doc.get("on", doc.get(True))
    paths = set((on.get(event) or {}).get("paths") or [])
    for p in needed:
        if p not in paths:
            print(f"FAIL {wf}: on.{event}.paths lacks '{p}', which mkdocs reads")
            fail = 1
if fail:
    sys.exit(1)
print(f"ok: {len(needed)} mkdocs inputs in both docs-site workflows")
PY
