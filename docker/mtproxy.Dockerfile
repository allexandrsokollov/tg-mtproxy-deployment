FROM quay.io/centos/centos:stream9 AS builder

ARG MTPROXY_COMMIT

RUN dnf install -y \
      gcc \
      git \
      make \
      openssl-devel \
      zlib-devel \
    && dnf clean all

RUN git clone https://github.com/TelegramMessenger/MTProxy.git /usr/src/mtproxy \
    && cd /usr/src/mtproxy \
    && git checkout --detach "${MTPROXY_COMMIT}" \
    && make -j"$(nproc)"

FROM quay.io/centos/centos:stream9

RUN dnf install -y \
      hostname \
      iproute \
      openssl-libs \
      zlib \
    && dnf clean all

COPY --from=builder /usr/src/mtproxy/objs/bin/mtproto-proxy /usr/local/bin/mtproto-proxy
COPY mtproxy-entrypoint.bash /usr/local/bin/mtproxy-entrypoint

RUN chmod 0755 /usr/local/bin/mtproto-proxy /usr/local/bin/mtproxy-entrypoint

ENV WORKERS=2

EXPOSE 443/tcp

ENTRYPOINT ["/usr/local/bin/mtproxy-entrypoint"]
