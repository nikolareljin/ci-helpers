# hosts

Helpers for editing `/etc/hosts`.

Functions
---------

- add_to_etc_hosts domain ip_address
  - Purpose: Append `ip_address` and `domain` to `/etc/hosts` when the domain is not already present.
  - Behavior: Uses `sudo` to write; prints success/info messages.

Dependencies
------------

- Write access to `/etc/hosts` (typically via `sudo`).

