# tg-mtproxy-deployment

Deploy multiple Telegram MTProxy containers behind an optional NGINX load balancer.

## Usage

```bash
./script.bash \
  --port-range 30000-30009 \
  --prefix proxy \
  --lb-port 8443
```

By default, the script builds `tg-mtproxy:local` directly from the pinned
[TelegramMessenger/MTProxy](https://github.com/TelegramMessenger/MTProxy) source.
It also builds `tg-mtproxy-nginx:local` for the load balancer. Both use a
Quay-hosted CentOS build base, so the default deployment does not use Docker
Hub. Run the script from a complete checkout because the local build files live
under `docker/`.

The default `--pull-policy missing` reuses the locally built image. Other
supported policies are:

- `--pull-policy always` to rebuild the local MTProxy image.
- `--pull-policy never` to require the local image to exist already.

The source is pinned to a full Git commit. A different official revision can be
built with `--mtproxy-commit SHA`.

To use an external image instead, disable the local build explicitly. Transient
registry failures are retried three times by default:

```bash
./script.bash \
  --port-range 30000-30009 \
  --prefix proxy \
  --lb-port 8443 \
  --build-local-image no \
  --image registry.example.com/telegram/proxy:1.4 \
  --pull-retries 3
```

An external load-balancer image can likewise be selected with
`--build-local-lb no --lb-image IMAGE`.

To deploy with an already-built local image without making build or proxy-image
registry requests:

```bash
./script.bash \
  --port-range 30000-30009 \
  --prefix proxy \
  --lb-port 8443 \
  --pull-policy never
```
