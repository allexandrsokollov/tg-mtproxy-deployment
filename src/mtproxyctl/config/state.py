from __future__ import annotations

from pathlib import Path

from mtproxyctl.config.models import DeploymentState, PortRange, PullPolicy
from mtproxyctl.errors import ConfigurationError

STATE_KEYS = (
    "FORMAT_VERSION",
    "PORT_RANGE",
    "PUBLIC_IP",
    "LB_PORT",
    "NAME_PREFIX",
    "IMAGE",
    "BUILD_LOCAL_IMAGE",
    "MTPROXY_COMMIT",
    "MTPROXY_PLATFORM",
    "LB_NAME",
    "LB_IMAGE",
    "BUILD_LOCAL_LB_IMAGE",
    "PULL_POLICY",
    "PULL_RETRIES",
    "PULL_RETRY_DELAY",
    "USE_DD_SECRET",
    "ENABLE_LB",
)


def load_deployment_state(path: Path) -> DeploymentState:
    if not path.is_file() or path.is_symlink():
        raise ConfigurationError(f"Deployment state is missing or unsafe: {path}")

    try:
        content = path.read_text()
    except OSError as exc:
        raise ConfigurationError(f"Unable to read deployment state: {path}") from exc
    return parse_deployment_state(content, path.parent)


def parse_deployment_state(content: str, workdir: Path) -> DeploymentState:
    values: dict[str, str] = {}
    for line in content.splitlines():
        key, separator, value = line.partition("=")
        if not separator or key not in STATE_KEYS or key in values:
            raise ConfigurationError(f"Invalid or duplicate deployment state field: {key}")
        values[key] = value

    missing = [key for key in STATE_KEYS if key not in values]
    if missing:
        raise ConfigurationError(f"Deployment state is missing fields: {', '.join(missing)}")
    if values["FORMAT_VERSION"] != "1":
        raise ConfigurationError(
            f"Unsupported deployment state version: {values['FORMAT_VERSION']}"
        )

    return DeploymentState(
        port_range=PortRange.parse(values["PORT_RANGE"]),
        public_ip=values["PUBLIC_IP"],
        load_balancer_port=_parse_non_negative_int(values["LB_PORT"], "LB_PORT"),
        name_prefix=values["NAME_PREFIX"],
        proxy_image=values["IMAGE"],
        build_local_proxy_image=_parse_yes_no(values["BUILD_LOCAL_IMAGE"], "BUILD_LOCAL_IMAGE"),
        mtproxy_commit=values["MTPROXY_COMMIT"],
        mtproxy_platform=values["MTPROXY_PLATFORM"],
        load_balancer_name=values["LB_NAME"],
        load_balancer_image=values["LB_IMAGE"],
        build_local_load_balancer_image=_parse_yes_no(
            values["BUILD_LOCAL_LB_IMAGE"], "BUILD_LOCAL_LB_IMAGE"
        ),
        pull_policy=_parse_pull_policy(values["PULL_POLICY"]),
        pull_retries=_parse_non_negative_int(values["PULL_RETRIES"], "PULL_RETRIES"),
        pull_retry_delay=_parse_non_negative_int(values["PULL_RETRY_DELAY"], "PULL_RETRY_DELAY"),
        use_dd_secret=_parse_yes_no(values["USE_DD_SECRET"], "USE_DD_SECRET"),
        enable_load_balancer=_parse_yes_no(values["ENABLE_LB"], "ENABLE_LB"),
        workdir=workdir,
    )


def _parse_non_negative_int(value: str, field: str) -> int:
    if not value.isdigit():
        raise ConfigurationError(f"{field} must be a non-negative integer")
    return int(value)


def _parse_yes_no(value: str, field: str) -> bool:
    if value == "yes":
        return True
    if value == "no":
        return False
    raise ConfigurationError(f"{field} must be yes or no")


def _parse_pull_policy(value: str) -> PullPolicy:
    try:
        return PullPolicy(value)
    except ValueError as exc:
        raise ConfigurationError(f"Invalid pull policy: {value}") from exc
