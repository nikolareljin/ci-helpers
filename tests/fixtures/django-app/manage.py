#!/usr/bin/env python3
"""A stand-in for Django's manage.py, implementing only what the preset drives.

Deliberately not Django: pulling the framework in would make this a test of pip
and of Django, and it would still not exercise anything in django.yml that this
does not.

What it does test is the part ci-helpers owns -- that the preset exports a
connection the project can actually use, applies the migration, and runs the
suite as a SEPARATE PROCESS against the SAME database. That last one is not
theoretical: ci_laravel.sh shipped with an in-memory sqlite database, where
`migrate` reported every migration applied and the next step could not find the
migrations table.

Real Django is proven by the projects that call this preset.
"""
import os
import sys


def fail(msg: str) -> "NoReturn":  # noqa: F821
    sys.stderr.write(f"fixture: {msg}\n")
    raise SystemExit(1)


def connect():
    """Open the database the preset told us to use, by whatever driver suits."""
    engine = os.environ.get("DJANGO_DB_ENGINE", "")
    if not engine:
        fail("DJANGO_DB_ENGINE is unset; the preset exported no connection")

    if engine == "sqlite":
        name = os.environ.get("DJANGO_DB_NAME", "")
        if not name or name == ":memory:":
            fail(f"DJANGO_DB_NAME is {name!r}; a file is required, because each "
                 "step is its own process")
        import sqlite3
        return sqlite3.connect(name), "?"

    url = os.environ.get("DATABASE_URL", "")
    if not url:
        fail(f"engine is {engine!r} but DATABASE_URL is unset")
    if engine == "pgsql":
        import psycopg  # installed by the preset's install_command in this leg
        return psycopg.connect(url), "%s"
    fail(f"this fixture has no driver for engine {engine!r}")


def main() -> None:
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""

    if cmd == "migrate":
        conn, _ = connect()
        # A plain cursor, not `with conn.cursor()`: psycopg's cursor is a
        # context manager and sqlite3's is not, so the `with` form works on
        # postgres and raises TypeError on sqlite. Found by running it.
        cur = conn.cursor()
        cur.execute("DROP TABLE IF EXISTS ci_helpers_probe")
        cur.execute("CREATE TABLE ci_helpers_probe (note varchar(64))")
        cur.execute("INSERT INTO ci_helpers_probe (note) VALUES ('written by migrate')")
        conn.commit()
        print("  Applying app.0001_initial... OK")

    elif cmd == "test":
        # 1. the connection must name the database the caller asked for, not a
        #    not a default the script fell back to. Either form works: an
        #    environment variable is what the self-test uses, and a positional
        #    argument is kept for running this fixture by hand.
        want = os.environ.get("EXPECT_DB_NAME") or (sys.argv[2] if len(sys.argv) > 2 else None)
        # Required for a server engine, because the self-test's postgres leg
        # exists to prove the preset reached the database it was told to. If the
        # expectation stops arriving -- which is exactly what the step-command
        # probe bug did to it -- this check would otherwise skip and the leg
        # would pass having verified nothing. sqlite runs with no expectation on
        # purpose: its database is a generated filename, not a caller's choice.
        if not want and os.environ.get("DJANGO_DB_ENGINE") != "sqlite":
            fail("no EXPECT_DB_NAME reached this step, so the database-name "
                 "check would have been skipped silently")

        # 2. and the connection the preset exported has to be usable from here,
        #    which is a different process from the one that migrated.
        conn, _ = connect()
        cur = conn.cursor()
        cur.execute("SELECT note FROM ci_helpers_probe")
        row = cur.fetchone()
        if not row or row[0] != "written by migrate":
            fail(f"the migration's row is not visible from this process: {row!r}")


        if want:
            got = os.environ.get("DJANGO_DB_NAME", "")
            if os.environ.get("DJANGO_DB_ENGINE") == "sqlite":
                got = os.path.basename(got)
            if want not in got:
                fail(f"expected the database to be {want!r}, the preset exported {got!r}")

        print(f"  Ran 2 tests  OK  [engine={os.environ.get('DJANGO_DB_ENGINE')}]")

    else:
        fail(f"unsupported command: {cmd!r}")


if __name__ == "__main__":
    main()
