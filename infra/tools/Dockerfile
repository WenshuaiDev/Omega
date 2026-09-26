FROM python:3.13.7-alpine3.22
ARG VERSION=dev
ARG COMMIT=unknown
LABEL org.opencontainers.image.version=$VERSION org.opencontainers.image.revision=$COMMIT
RUN apk add --no-cache openssl=3.5.8-r0 libssl3=3.5.8-r0 libcrypto3=3.5.8-r0 && pip install --no-cache-dir PyYAML==6.0.2
COPY infra/tools/inputs.py /tools/inputs.py
COPY infra/tools/release.py /tools/release.py
COPY infra/tools/compose_policy.py /tools/compose_policy.py
COPY infra/edge/nginx.conf.template /tools/nginx.conf.template
ENTRYPOINT []
CMD ["python", "/tools/inputs.py", "--help"]
