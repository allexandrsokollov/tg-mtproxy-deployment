# tg-mtproxy-deployment

Deploy multiple Telegram MTProxy containers behind an optional NGINX load balancer.

## Usage

```bash
./script.bash \
  --port-range 30000-30009 \
  --prefix proxy \
  --lb-port 8443
```

The default `--pull-policy missing` reuses locally cached images and only contacts
the registry when an image is absent. Other supported policies are:

- `--pull-policy always` to check for updated images before deployment.
- `--pull-policy never` to require images to be preloaded locally.

Transient registry failures are retried three times by default. Change this with
`--pull-retries N`.

If Docker Hub rate-limits the server, authenticate with `docker login`, wait for
the limit to clear, or select a trusted registry mirror:

```bash
./script.bash \
  --port-range 30000-30009 \
  --prefix proxy \
  --lb-port 8443 \
  --image registry.example.com/telegram/proxy:1.4
```

To deploy with an image that is already cached without making registry requests:

```bash
./script.bash \
  --port-range 30000-30009 \
  --prefix proxy \
  --lb-port 8443 \
  --pull-policy never
```
