#!/usr/bin/env bash
# Stands for vendored code under the default exclude_glob. Deliberately SC2044
# (warning): it must be excluded, or the passing leg that checks scripts/ fails.
for f in $(find . -name '*.txt'); do
  echo "$f"
done
