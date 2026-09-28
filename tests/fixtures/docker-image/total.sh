#!/bin/sh
# The build runs this, so a broken image fails `docker build` rather than
# producing something that only fails when somebody runs it.
#
# The argument check is not decoration: in ash, `$((sum + not-a-number))`
# evaluates to 0 and exits 0, so without it `total abc` answers 0 -- a fixture
# that lies about its own arithmetic is worse than no fixture.
set -eu

sum=0
for amount in "$@"; do
  case "$amount" in
    ''|*[!0-9-]*)
      echo "total: not a number: $amount" >&2
      exit 2
      ;;
  esac
  sum=$((sum + amount))
done
echo "$sum"
