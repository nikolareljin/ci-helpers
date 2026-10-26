# django-install fixture

Drives `django.yml` with its default `install_command` (empty), which must
install `requirements.txt` and then `requirements-dev.txt` when each exists.
They install `probe/` and `probe-dev/`, packages with one module each, and the
leg's test imports both: a skipped install of either file fails the leg.
