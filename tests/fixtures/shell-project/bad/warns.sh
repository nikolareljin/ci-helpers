#!/usr/bin/env bash
# Deliberately SC2044 (warning): iterating find's output word-splits on a path
# with a space. Warning severity on purpose -- the default the preset ships --
# so a fixture that only tripped `info` would prove nothing about that default.
for f in $(find . -name '*.txt'); do
  echo "$f"
done
