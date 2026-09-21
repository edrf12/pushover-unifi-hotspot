FROM rust:1.98-bookworm AS builder

RUN apt-get update \
    && apt-get install -y --no-install-recommends cmake \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release --locked

FROM quay.io/fedora/fedora-minimal:44 AS runtime

RUN microdnf install -y ca-certificates --setopt=install_weak_deps=0 \
    && microdnf clean all

COPY --from=builder /app/target/release/pushover-unifi-hotspot /usr/local/bin/pushover-unifi-hotspot

USER 10001:10001
EXPOSE 3000
ENTRYPOINT ["/usr/local/bin/pushover-unifi-hotspot"]
