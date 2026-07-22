# wrk built from a pinned upstream tag. We build it ourselves rather than pull
# a third-party image so the load generator is reproducible and auditable.
FROM alpine:3.20 AS build
RUN apk add --no-cache build-base git openssl-dev zlib-dev perl linux-headers
RUN git clone --depth 1 --branch 4.2.0 https://github.com/wg/wrk.git /src \
    && make -C /src -j"$(nproc)"

FROM alpine:3.20
RUN apk add --no-cache libgcc libstdc++ openssl
COPY --from=build /src/wrk /usr/local/bin/wrk
ENTRYPOINT ["wrk"]
