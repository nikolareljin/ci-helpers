# django-install fixture

Drives `django.yml` with its default `install_command` (empty), which must run
`pip install -r requirements.txt` when the file exists. `requirements.txt`
installs `probe/`, a package with one module, and the leg's test is importing
it: a skipped install fails the leg.
