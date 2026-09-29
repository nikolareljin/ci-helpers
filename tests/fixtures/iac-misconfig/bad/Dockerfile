# Wrong on purpose: no USER, so the image runs as root. Trivy's Dockerfile
# rules report that as DS-0002 at HIGH severity.
#
# Do not add a USER line here. The finding is the point.
FROM alpine:3.20
RUN apk add --no-cache curl
CMD ["sh"]
