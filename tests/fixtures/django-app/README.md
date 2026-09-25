# django-app fixture

Drives `django.yml` end to end without pulling in Django.

`manage.py` implements only `migrate` and `test`, and each asserts something the
preset is responsible for:

| Command | What a green run proves |
|---|---|
| `migrate` | the exported connection reaches a database that accepts writes |
| `test` | the migration's row is visible **from a different process**, and the connection names the database the caller asked for |

That second one is why this fixture is not a `true` command. `ci_laravel.sh`
once used an in-memory sqlite database: `migrate` reported every migration
applied and the next step answered "Migration table not found". A fixture that
only checked exit codes would have passed.

The postgres leg installs `psycopg` through the preset's own `install_command`
and really connects, rather than inspecting `DATABASE_URL` and believing it.

It is not a test of Django. Real Django is proven by the projects that call this
preset.
