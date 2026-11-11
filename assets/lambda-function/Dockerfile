# Downloads the control plane of k8s-sealed-secrets-sealer
# (cruxstack/k8s-sealed-secrets-sealer) for AWS Lambda (provided.al2023)
# from one of its GitHub releases: a zip holding `bootstrap`, with the web UI
# embedded. The zip must match the release's checksums.txt.

# ----------------------------------------------------------------- download ---

FROM alpine:3.24 AS download

# a release tag of k8s-sealed-secrets-sealer, and the repository it is
# released from (owner/name, for forks)
ARG APP_VERSION=v0.10.0
ARG APP_REPO=cruxstack/k8s-sealed-secrets-sealer
ARG GOARCH=arm64

RUN apk add --no-cache curl

WORKDIR /tmp/release

RUN set -eu; \
    asset="k8s-sealed-secrets-sealer-lambda_${GOARCH}.zip"; \
    base="https://github.com/${APP_REPO}/releases/download/${APP_VERSION}"; \
    curl -fsSL --retry 3 -o checksums.txt "${base}/checksums.txt"; \
    curl -fsSL --retry 3 -o "${asset}" "${base}/${asset}"; \
    awk -v asset="${asset}" '$2 == asset' checksums.txt > expected.txt; \
    if [ "$(wc -l < expected.txt)" -ne 1 ]; then \
      echo "error: ${base}/checksums.txt has no single line for ${asset}" >&2; \
      exit 1; \
    fi; \
    sha256sum -c expected.txt; \
    unzip -l "${asset}" bootstrap > /dev/null \
      || { echo "error: ${asset} holds no bootstrap" >&2; exit 1; }; \
    mv "${asset}" /tmp/package.zip

# ------------------------------------------------------------------ package ---

FROM scratch AS package

COPY --from=download /tmp/package.zip /tmp/package.zip
