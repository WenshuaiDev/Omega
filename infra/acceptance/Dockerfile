FROM docker:29.8.0-dind@sha256:5efed980cba3fc126cf54e21a5a6ff8849d05b6e0623d6e7612f48e9cd6cd17e
# Acceptance host tooling, never part of the application release. The resulting
# harness content ID and installed package versions are recorded by the drill.
RUN apk add --no-cache bash curl coreutils tar openssl
