FROM nginx:1.28.0-alpine
ARG VERSION=dev
ARG COMMIT=unknown
LABEL org.opencontainers.image.version=$VERSION org.opencontainers.image.revision=$COMMIT
USER 101:101
ENTRYPOINT ["nginx"]
CMD ["-g", "daemon off;"]
