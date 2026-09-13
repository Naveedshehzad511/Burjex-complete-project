FROM rust:1.88-bookworm AS build
WORKDIR /app
RUN apt-get update \
  && apt-get install -y --no-install-recommends pkg-config libssl-dev \
  && rm -rf /var/lib/apt/lists/*
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates libssl3 \
  && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/target/release/btrader-matching /usr/local/bin/btrader-matching
ENV ENGINE_HTTP_PORT=4300
EXPOSE 4300
CMD ["btrader-matching"]
