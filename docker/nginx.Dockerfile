FROM quay.io/centos/centos:stream9

RUN dnf install -y \
      nginx \
      nginx-mod-stream \
    && dnf clean all

EXPOSE 443/tcp

STOPSIGNAL SIGQUIT

CMD ["nginx", "-g", "daemon off;"]
