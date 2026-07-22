# ApacheBench (ab) load generator — a cross-check that mirrors the OLDER vendor
# methodology (dev.to, Sept 2025: ab, 50k requests, 1000 concurrent, no flags
# documented). Built from alpine's apache2-utils so the ab version is pinned to
# the alpine release (ApacheBench 2.3). Kept entirely separate from wrk: ab uses
# no keep-alive and is not our published methodology.
FROM alpine:3.20
RUN apk add --no-cache apache2-utils
ENTRYPOINT ["ab"]
