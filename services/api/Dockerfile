FROM golang:1.27.1-bookworm AS development
WORKDIR /workspace
ENV GOTOOLCHAIN=local
CMD ["go", "run", "./services/api/cmd/omega-api", "--config", "/etc/omega/app.yaml"]

FROM development AS build
ARG VERSION
ARG COMMIT
COPY go.work ./
COPY services/api ./services/api
RUN test -n "$VERSION" && test -n "$COMMIT" && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X github.com/WenshuaiDev/Omega/services/api/internal/app.Version=$VERSION -X github.com/WenshuaiDev/Omega/services/api/internal/app.Commit=$COMMIT" -o /out/omega ./services/api/cmd/omega && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X github.com/WenshuaiDev/Omega/services/api/internal/app.Version=$VERSION -X github.com/WenshuaiDev/Omega/services/api/internal/app.Commit=$COMMIT" -o /out/omega-api ./services/api/cmd/omega-api

FROM scratch AS production
ARG VERSION
ARG COMMIT
LABEL org.opencontainers.image.version=$VERSION org.opencontainers.image.revision=$COMMIT
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /out/ /usr/local/bin/
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["omega-api"]
CMD ["--config", "/etc/omega/app.yaml"]
