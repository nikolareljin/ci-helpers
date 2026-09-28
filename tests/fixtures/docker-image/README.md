# docker-image fixture

Drives `docker.yml` at its shipped default, `docker build .`, and gives
`docker-scan.yml` something to build and scan.

The base is pinned by digest and the build runs the script it copies, so a
broken image fails the build rather than producing something that only fails
when somebody runs it.

`docker-scan.yml`'s Snyk step needs `snyk_token` and stays unexercised; the
Trivy half runs without a credential, which is as far as verification goes
here.
