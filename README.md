# MTProxy deployment control plane

`mtproxyctl` manages a pool of Telegram MTProxy containers, an optional NGINX
TCP load balancer, protected backups, Grafana Cloud monitoring, and a separate
macOS Minikube development environment.

```text
mtproxyctl
├── doctor
├── deploy      plan | apply | status | redeploy
├── backup      create | list | verify | restore | prune
├── monitoring  install | configure | collect | status | verify
└── dev minikube
                setup | status
```

Python owns configuration, validation, backup safety, status inspection, and
metric collection. The compatibility release still uses the included Bash
scripts for privileged host provisioning.

## Requirements

- Python 3.12+
- Ubuntu for production deployment
- Debian or Ubuntu with systemd for Grafana Alloy
- `sudo`, outbound internet access, and a public IPv4 address
- macOS with Homebrew for the optional Minikube workflow

`deploy apply` may install/remove host packages, install Docker, replace managed
containers, update cron, modify UFW rules, and write protected deployment state.
Preview it first:

```bash
mtproxyctl deploy plan
mtproxyctl --dry-run deploy apply
```

The global `--dry-run` option must appear before the command.

## Quick start

Install from a complete checkout:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install .
```

Create the configuration:

```bash
cp .env.example .env
chmod 600 .env
${EDITOR:-vi} .env
```

At minimum, review:

```dotenv
MTPROXYCTL_PROJECT_DIR=/absolute/path/to/tg-mtproxy-deployment
MTPROXYCTL_DEPLOYMENT__WORKDIR=/home/ubuntu/mtproxy
MTPROXYCTL_DEPLOYMENT__PORT_RANGE=30000-30009
MTPROXYCTL_DEPLOYMENT__PUBLIC_IP=203.0.113.10
MTPROXYCTL_DEPLOYMENT__LOAD_BALANCER_PORT=8443
```

Replace the example IP with the server's public IPv4 address. Then run:

```bash
mtproxyctl doctor
mtproxyctl deploy plan
mtproxyctl deploy apply
mtproxyctl deploy status
mtproxyctl backup create
```

The successful deployment prints Telegram links containing the client secret.
Treat terminal recordings and copied output as sensitive.

## Configuration

Settings are loaded and validated by `pydantic-settings`. Nested settings use a
double underscore:

```dotenv
MTPROXYCTL_DEPLOYMENT__PULL_POLICY=missing
MTPROXYCTL_DEPLOYMENT__ENABLE_LOAD_BALANCER=true
MTPROXYCTL_BACKUP__BACKUP_DIR=/home/ubuntu/mtproxy-backups
MTPROXYCTL_MONITORING__EXPECTED_COUNT=10
MTPROXYCTL_MINIKUBE__CPUS=4
```

Precedence, from strongest to weakest:

1. CLI arguments
2. Process environment variables
3. The selected `.env`
4. Built-in defaults

Use another dotenv file with:

```bash
mtproxyctl --env-file /etc/mtproxyctl/production.env deploy plan
```

The default `.env` is read from the current directory. See
[`.env.example`](.env.example) for every supported variable and use
`mtproxyctl COMMAND --help` for CLI options.

Do not confuse these files:

- `.env` contains operator-owned application defaults.
- `~/mtproxy/deployment.env` is generated non-secret state used by redeploy,
  monitoring discovery, and restore validation.

## Deployment

Plan, apply, inspect, or recreate the deployment:

```bash
mtproxyctl deploy plan
mtproxyctl deploy apply
mtproxyctl deploy status
mtproxyctl deploy redeploy
```

Without `.env`, provide the required port range:

```bash
mtproxyctl --env-file /dev/null deploy apply \
  --port-range 30000-30009 \
  --public-ip 203.0.113.10 \
  --lb-port 8443 \
  --prefix proxy
```

Use external images:

```bash
mtproxyctl deploy apply \
  --no-build-local-image \
  --image registry.example.com/telegram/proxy:1.4 \
  --no-build-local-lb \
  --lb-image registry.example.com/infrastructure/nginx:1.27
```

Pull policies are `missing`, `always`, and `never`. Disable NGINX with
`--no-enable-lb`.

The deployment normally generates and preserves its secret. To provide one:

```bash
umask 077
python -c 'import secrets; print(secrets.token_hex(16))' \
  > /protected/path/mtproxy-secret

mtproxyctl deploy apply \
  --secret-file /protected/path/mtproxy-secret
```

## State and backups

The work directory defaults to `~/mtproxy`, uses mode `0700`, and contains:

- `mtproxy-secret`
- `proxy-secret`
- `proxy-multi.conf`
- `deployment.env`
- optional `nginx.conf` and `docker-compose.yml`

Create and verify a backup:

```bash
mtproxyctl backup create
mtproxyctl backup list
mtproxyctl backup verify ARCHIVE
```

Restore into an empty directory:

```bash
mtproxyctl backup restore ARCHIVE \
  --workdir /srv/recovered-mtproxy
```

Overwrite and immediately redeploy:

```bash
mtproxyctl backup restore ARCHIVE \
  --workdir ~/mtproxy \
  --force \
  --redeploy
```

Apply retention:

```bash
mtproxyctl --dry-run backup prune --keep 10 --yes
mtproxyctl backup prune --keep 10 --yes
```

Backups contain credentials. Checksums detect accidental corruption but do not
provide encryption or authenticity. Store archives using encrypted transport
and encrypted off-host storage.

Restore rejects traversal paths, links, devices, unexpected files, unsafe
sizes, invalid checksums, invalid secrets, and invalid deployment state.

## Grafana Cloud monitoring

Monitoring sends host and container metrics, Docker logs, and native MTProxy
`/stats` values without publishing port `2398`.

Create an access-policy token with `metrics:write` and `logs:write`, then place
it in a protected file:

```bash
sudo install -d -m 0750 /etc/mtproxyctl
sudo install -m 0600 /dev/null /etc/mtproxyctl/grafana-cloud-token
sudoedit /etc/mtproxyctl/grafana-cloud-token
```

Configure `.env`:

```dotenv
MTPROXYCTL_MONITORING__METRICS_URL=https://PROMETHEUS-ENDPOINT/api/prom/push
MTPROXYCTL_MONITORING__METRICS_USER=METRICS-INSTANCE-ID
MTPROXYCTL_MONITORING__LOGS_URL=https://LOKI-ENDPOINT/loki/api/v1/push
MTPROXYCTL_MONITORING__LOGS_USER=LOGS-INSTANCE-ID
MTPROXYCTL_MONITORING__TOKEN_FILE=/etc/mtproxyctl/grafana-cloud-token
MTPROXYCTL_MONITORING__DEPLOYMENT_STATE=/home/ubuntu/mtproxy/deployment.env
```

Install and verify:

```bash
mtproxyctl monitoring install
mtproxyctl monitoring status
mtproxyctl monitoring verify
```

If Alloy has an unmanaged configuration, review it before running:

```bash
mtproxyctl monitoring configure --force
```

Manual checks:

```bash
sudo .venv/bin/mtproxyctl \
  --env-file "$PWD/.env" \
  --project-dir "$PWD" \
  monitoring collect

sudo cat /var/lib/alloy/textfile/mtproxy.prom
curl -fsS http://127.0.0.1:12345/-/healthy
```

In Grafana Cloud, also create a synthetic TCP check, alert rules, and a Telegram
contact point.

## macOS Minikube

The development workflow installs Minikube, kubectl, QEMU, and `socket_vmnet`
with Homebrew.

```bash
mtproxyctl dev minikube setup
mtproxyctl dev minikube status
```

Persistent service forwarding requires all four forwarding arguments:

```bash
mtproxyctl dev minikube setup \
  --profile mtproxy-dev \
  --pf-namespace default \
  --pf-service my-service \
  --pf-local-port 8080 \
  --pf-remote-port 80
```

## Troubleshooting

- **Compatibility script missing:** run from the checkout, set
  `MTPROXYCTL_PROJECT_DIR`, or pass `--project-dir`.
- **`.env` ignored:** run from its directory or pass `--env-file`.
- **Docker permission denied:** use an account allowed to access Docker or run
  the command with the required privilege.
- **Port conflict:** keep the load-balancer port outside the proxy range.
- **Restore refuses to overwrite:** verify the archive and target, then use
  `--force` deliberately.
- **Metrics missing:** inspect `alloy` and
  `mtproxy-stats-collector.timer` with `systemctl` and `journalctl`.

## Compatibility scripts

`mtproxyctl` is the primary interface. Direct scripts remain available for
migration and low-level recovery:

```bash
./script.bash --port-range 30000-30009 --lb-port 8443
./backup.bash backup
sudo ./monitoring-setup.bash --help
bash ./minikube-deployment.bash --help
```

## Development

```bash
python -m pip install -e '.[dev]'

ruff format src tests_python
ruff check src tests_python --fix --unsafe-fixes
mypy src tests_python
pytest

for test_script in tests/*_test.bash; do
  bash "$test_script"
done
```
