# tg-mtproxy-deployment

Deploy multiple Telegram MTProxy containers behind an optional NGINX load balancer.

## Python management application

`mtproxyctl` provides one typed command-line interface for deployment, protected
backups, monitoring, and the optional macOS Minikube environment. The first
compatibility release keeps the proven Bash deployment and privileged setup
scripts as execution backends while Python owns validation, safe backup
handling, deployment inspection, and MTProxy metric collection.

Install it from this checkout:

```bash
python3 -m pip install .
mtproxyctl doctor
```

Run `mtproxyctl` from this checkout, pass `--project-dir PATH`, or set
`MTPROXYCTL_PROJECT_DIR` so the compatibility release can locate its privileged
backend scripts.

Application defaults are managed by `pydantic-settings`. Copy `.env.example`
to `.env` and adjust the `MTPROXYCTL_` variables as needed:

```bash
cp .env.example .env
mtproxyctl deploy plan
```

Nested settings use a double underscore, for example
`MTPROXYCTL_DEPLOYMENT__PORT_RANGE`. Real environment variables override
values in `.env`, and explicit CLI arguments override both. Use
`--env-file PATH` to select a different dotenv file. Keep credentials in
protected files and configure only their paths, such as
`MTPROXYCTL_MONITORING__TOKEN_FILE`.

Preview and apply a deployment:

```bash
mtproxyctl deploy plan \
  --port-range 30000-30009 \
  --public-ip 203.0.113.10 \
  --lb-port 8443

mtproxyctl deploy apply \
  --port-range 30000-30009 \
  --public-ip 203.0.113.10 \
  --lb-port 8443
```

Secrets are accepted through `--secret-file`, rather than as command-line
values. All mutating command groups support a global dry-run:

```bash
mtproxyctl --dry-run deploy apply --port-range 30000-30009
```

Create, verify, and restore a versioned backup:

```bash
mtproxyctl backup create
mtproxyctl backup verify ~/mtproxy-backups/mtproxy-TIMESTAMP-PID.tar.gz
mtproxyctl backup restore ~/mtproxy-backups/mtproxy-TIMESTAMP-PID.tar.gz
```

The Python backup format adds per-file SHA-256 checksums and safe archive
validation. Backups created by the existing `backup.bash` format remain
readable.

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

## Grafana Cloud monitoring

`monitoring-setup.bash` configures Grafana Alloy as a system service and sends:

- Linux host CPU, memory, disk, systemd, and network metrics.
- Per-container cAdvisor metrics.
- Docker container logs.
- Native MTProxy `/stats` values collected without exposing port `2398`.

Create a Grafana Cloud access-policy token with `metrics:write` and `logs:write`,
save it in a protected local file, then run:

```bash
sudo ./monitoring-setup.bash \
  --metrics-url https://PROMETHEUS-ENDPOINT/api/prom/push \
  --metrics-user METRICS-INSTANCE-ID \
  --logs-url https://LOKI-ENDPOINT/loki/api/v1/push \
  --logs-user LOGS-INSTANCE-ID \
  --token-file /protected/path/grafana-cloud-token \
  --deployment-state /home/ubuntu/mtproxy/deployment.env
```

The endpoint URLs and instance IDs are available in Grafana Cloud under
**Connections → Linux Server → Configure**. If Alloy already has an unmanaged
configuration, pass `--force` to create a timestamped backup and replace it.

The setup script intentionally leaves two account-level tasks in the Grafana
Cloud UI: create a Synthetic Monitoring TCP check for the public load-balancer
port, and route alert rules to a Telegram contact point.

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
