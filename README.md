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

## Persistent state and backups

The deployment work directory (by default `~/mtproxy`) is the source of truth
for machine-local state:

- `mtproxy-secret` is the stable client secret used by every proxy instance.
- `proxy-secret` and `proxy-multi.conf` are Telegram runtime files.
- `deployment.env` records the non-secret settings required to reproduce the
  proxy range, images, public IP, and load balancer.
- `nginx.conf` and `docker-compose.yml` record the generated load-balancer
  configuration when the load balancer is enabled.

The directory is mode `0700`; sensitive files and generated state are mode
`0600`.

Create a protected backup after deployment:

```bash
./backup.bash backup
```

By default this writes a mode-`0600` archive under `~/mtproxy-backups`, outside
the live work directory. The archive contains credentials, so store any copied
version using encrypted storage or an encrypted transport.

Restore files into an empty work directory:

```bash
./backup.bash restore ~/mtproxy-backups/mtproxy-TIMESTAMP-PID.tar.gz
```

If the work directory already contains deployment state, restoration refuses
to overwrite it unless `--force` is explicit. Restore and recreate all
containers and the load balancer in one command:

```bash
./backup.bash restore ~/mtproxy-backups/mtproxy-TIMESTAMP-PID.tar.gz \
  --force \
  --redeploy
```

To recreate the deployment later from the existing live state without first
restoring an archive:

```bash
./backup.bash redeploy
```

The backup intentionally excludes Docker images: local images can be rebuilt
from this checkout at the pinned MTProxy commit. If a deployment uses private
external images, preserve the registry credentials separately.
