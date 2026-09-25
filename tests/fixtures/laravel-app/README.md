# laravel-app fixture

Drives `laravel.yml` end to end without pulling in `laravel/framework`.

`artisan` implements only `key:generate`, `config:clear`, `migrate` and `test`,
and each one asserts something the preset is responsible for:

| Command | What a green run proves |
|---|---|
| `key:generate` | the preset created `.env` from `.env.example` and the key was absent |
| `migrate` | the exported `DB_*` reach a database that accepts writes |
| `test` | `APP_KEY` is in `.env`, and the migration's row is visible **from a different process** |

That last one is the reason this fixture exists rather than a `true` command.
`ci_laravel.sh` once used an in-memory sqlite database: `migrate` reported every
migration DONE and the next step answered "Migration table not found". A fixture
that only checked exit codes would have passed.

It is not a test of Laravel. Real Laravel is proven by the applications that
call this preset.
