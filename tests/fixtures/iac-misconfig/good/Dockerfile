# The same image with the finding fixed, so a green scan means the scan ran
# rather than that every Dockerfile passes.
FROM alpine:3.20
RUN apk add --no-cache curl
USER nobody
HEALTHCHECK CMD ["true"]
CMD ["sh"]
