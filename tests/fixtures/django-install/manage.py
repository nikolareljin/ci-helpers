#!/usr/bin/env python3
"""Never run: ci_django.sh refuses a directory without a manage.py, and this
fixture's leg skips migrate and the drift check."""
import sys

sys.exit("django-install fixture: manage.py is not used")
