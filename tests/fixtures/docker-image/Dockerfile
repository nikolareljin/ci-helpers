# Small, pinned by digest, and built from a base that is already on every
# runner: a fixture that pulls a large image spends the leg's time on the pull
# rather than on the preset under test.
FROM alpine:3.21@sha256:56fa17d2a7e7f168a043a2712e63aed1f8543aeafdcee47c58dcffe38ed51099

COPY total.sh /usr/local/bin/total
RUN chmod +x /usr/local/bin/total \
    # Checked at build time, so `docker build` is the thing that fails when the
    # image is wrong -- which is what the preset's default runs.
    && test "$(total 1 2 39)" = "42" \
    && ! total abc 2>/dev/null

ENTRYPOINT ["total"]
