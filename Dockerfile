# syntax=docker/dockerfile:1
#
# The self-hosted Macpardy buzzer server (#103). Build from this directory:
#
#   docker build -t macpardy-buzzer-server .
#
# It speaks plain HTTP; put a reverse proxy that handles HTTPS in front of it
# (see docker-compose.yml and README.md).

# ── Build ──────────────────────────────────────────────────────────────────
FROM swift:6.2-noble AS build
WORKDIR /build

# Dependencies first, so they're cached between source changes.
COPY Package.swift Package.resolved ./
RUN swift package resolve

COPY Sources ./Sources
COPY Tests ./Tests
RUN swift build -c release --product macpardy-buzzer-server --static-swift-stdlib \
 && BIN="$(swift build -c release --show-bin-path)" \
 && mkdir /staging \
 && cp "$BIN/macpardy-buzzer-server" /staging/ \
 && cp -R "$BIN/MacpardyBuzzer_BuzzerWebPage.resources" /staging/

# ── Run ────────────────────────────────────────────────────────────────────
FROM ubuntu:noble

RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin macpardy
COPY --from=build /staging /app

USER macpardy
ENV MACPARDY_PORT=8472 \
    MACPARDY_BIND=0.0.0.0
EXPOSE 8472

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["/app/macpardy-buzzer-server", "healthcheck"]

ENTRYPOINT ["/app/macpardy-buzzer-server"]
