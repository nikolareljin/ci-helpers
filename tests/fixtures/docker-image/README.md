# docker-image fixture

Drives `docker.yml` at its shipped default, `docker build .`, and gives
`docker-scan.yml` something to build and scan.

The base is pinned by digest and the build runs the script it copies, so a
broken image fails the build rather than producing something that only fails
when somebody runs it.

`docker-scan.yml` runs the pinned Trivy binary against the built image. Snyk
is disabled there; the `run_snyk` warning step is driven by
`docker-refuses-what-it-must` in `self-test.yml`.
