"""Deliberately vulnerable, so the CodeQL leg can be shown to find something.

A request parameter reaches `os.system`. That is `py/command-line-injection`,
in CodeQL's default query suite, and it needs no packages installed: CodeQL
models Flask itself.

Nothing imports this module. It exists to be analysed, and a leg fails if
CodeQL stops reporting it -- an analysis that located no source reports no
findings, which reads exactly like a clean one.
"""

from __future__ import annotations

import os

from flask import Flask, request

app = Flask(__name__)


@app.route("/ping")
def ping() -> str:
    host = request.args.get("host", "")
    os.system("ping -c 1 " + host)
    return "sent"
