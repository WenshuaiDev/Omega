FROM node:24.21.0-bookworm-slim AS dependencies
ENV COREPACK_HOME=/opt/corepack
RUN corepack enable && corepack prepare yarn@4.18.1 --activate
WORKDIR /workspace
COPY . /workspace
RUN yarn install --immutable

# Browser/system dependencies are acceptance tooling, never a production image.
FROM mcr.microsoft.com/playwright:v1.63.0-noble@sha256:eff16c30e6f3f4af0a03fa4b706120d5e9b0891c344a27d64559aff5900a4a27
WORKDIR /opt/omega-browser
COPY --from=dependencies /workspace/node_modules/playwright-core ./node_modules/playwright-core
COPY scripts/acceptance/browser.mjs ./browser.mjs
ENTRYPOINT ["node", "/opt/omega-browser/browser.mjs"]
