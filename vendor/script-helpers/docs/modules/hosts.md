# hosts

Helpers for editing `/etc/hosts`.

Functions
---------

- add_to_etc_hosts domain ip_address
  - Purpose: Append `ip_address` and `domain` to the hosts file when the domain
    is not already present.
  - Behavior: Writes directly when the file is writable, otherwise through
    `sudo tee`. Prints a success or info message.
  - Env:
    - `HOSTS_FILE` — the file to edit, default `/etc/hosts`. Provided so the
      "already present" test is verifiable without touching the real file.
  - Returns: `0` when the entry was added or already present, `2` when the
    domain or the IP is missing.
  - Notes: the presence test compares whitespace-separated tokens exactly and
    skips comment lines, rather than interpolating the domain into a `grep`
    pattern. Two bugs made that necessary: GNU `\s` is not POSIX and BSD grep
    never matches it, so on macOS the check always concluded "absent" and
    appended a duplicate line on every call; and a domain carries its own dots
    into a regex, where `.` matches any character, so `demo.local` was found in
    a file holding only `demoXlocal` and the real entry was never added.

Dependencies
------------

- Write access to the hosts file, directly or via `sudo`.
