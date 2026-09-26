FROM node:24.21.0-bookworm-slim AS development
ENV COREPACK_HOME=/opt/corepack
RUN corepack enable && corepack prepare yarn@4.18.1 --activate
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
WORKDIR /workspace
EXPOSE 5173
USER node

FROM development AS build
USER root
COPY . /workspace
RUN yarn install --immutable
ARG APP
RUN case "$APP" in web|console) ;; *) exit 2 ;; esac && yarn workspace "@omega/$APP" build && mkdir /out && cp -r "apps/$APP/dist/." /out/

FROM nginx:1.28.0-alpine AS production
ARG APP
ARG VERSION=dev
ARG COMMIT=unknown
LABEL org.opencontainers.image.version=$VERSION org.opencontainers.image.revision=$COMMIT
COPY apps/nginx.conf /etc/nginx/nginx.conf
COPY --from=build /out/ /usr/share/nginx/html/
RUN case "$APP" in web|console) ;; *) exit 2 ;; esac && sed -i "s|APP_BASE|$APP|g" /etc/nginx/nginx.conf
USER nginx
EXPOSE 8080
ENTRYPOINT ["nginx", "-g", "daemon off;"]
