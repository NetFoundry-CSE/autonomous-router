# Pre-Build ziti_router_auto_enroll binary
FROM ubuntu:focal AS build
RUN apt-get -o Acquire::Check-Valid-Until=false \
            -o Acquire::Check-Date=false \
        update \
    && apt-get install -y --no-install-recommends \
        jq curl procps iproute2 python3 python3-pip libpython3.8 binutils \
    && rm -rf /var/lib/apt/lists/*
RUN pip3 install --no-cache-dir \
        -r https://raw.githubusercontent.com/netfoundry/ziti_router_auto_enroll/main/requirements.txt
ADD https://raw.githubusercontent.com/netfoundry/ziti_router_auto_enroll/main/ziti_router_auto_enroll.py /
RUN pyinstaller -F /ziti_router_auto_enroll.py

# Build the final image
FROM cgr.dev/chainguard/wolfi-base
RUN apk update && apk add --no-cache \
        bash \
        curl \
        jq \
        iproute2 \
        systemd \
        yq \
        bind-tools
COPY --from=build /dist/ziti_router_auto_enroll /
COPY ./docker-entrypoint.sh ./aer-lib.sh /
RUN chmod +x /docker-entrypoint.sh /ziti_router_auto_enroll

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["run"]