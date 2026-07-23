from __future__ import annotations

import os
from pathlib import Path
import re
import time

from mtproxyctl.config.models import NAME_PATTERN
from mtproxyctl.config.state import load_deployment_state
from mtproxyctl.deployment.models import ProjectPaths
from mtproxyctl.errors import (
    CommandExecutionError,
    ConfigurationError,
    MonitoringError,
)
from mtproxyctl.infrastructure.commands import CommandRunner, CommandSpec
from mtproxyctl.infrastructure.files import write_text_atomically
from mtproxyctl.monitoring.models import (
    MonitoringInstallRequest,
    MonitoringStatus,
    MonitoringTarget,
)

METRIC_NAMES = (
    "workers",
    "qps_get",
    "total_ready_targets",
    "total_allocated_targets",
    "total_declared_targets",
    "total_inactive_targets",
    "total_connections",
    "total_encrypted_connections",
    "total_special_connections",
    "total_max_special_connections",
    "ext_connections",
    "ext_connections_created",
    "total_network_buffers_used_size",
    "total_network_buffers_allocated_bytes",
    "mtproto_proxy_errors",
    "connections_failed_lru",
    "connections_failed_flood",
)
NUMBER_PATTERN = re.compile(r"^-?[0-9]+(?:\.[0-9]+)?$")
HTTPS_URL_PATTERN = re.compile(r"^https://[A-Za-z0-9./:_?=%+\-]+$")
USERNAME_PATTERN = re.compile(r"^[A-Za-z0-9_-]+$")


class MonitoringService:
    def __init__(self, runner: CommandRunner, project_paths: ProjectPaths) -> None:
        self._runner = runner
        self._project_paths = project_paths

    def install(self, request: MonitoringInstallRequest) -> None:
        _validate_install_request(request)
        script = self._project_paths.monitoring_script
        if not script.is_file():
            raise ConfigurationError(f"Monitoring setup script is missing: {script}")
        argv = [
            str(script),
            "--metrics-url",
            request.metrics_url,
            "--metrics-user",
            request.metrics_user,
            "--logs-url",
            request.logs_url,
            "--logs-user",
            request.logs_user,
            "--token-file",
            str(request.token_file),
        ]
        if request.deployment_state is not None:
            argv.extend(("--deployment-state", str(request.deployment_state)))
        if request.name_prefix is not None:
            argv.extend(("--prefix", request.name_prefix))
        if request.expected_count is not None:
            argv.extend(("--expected-count", str(request.expected_count)))
        if request.force:
            argv.append("--force")
        if os.geteuid() != 0:
            argv.insert(0, "sudo")
        self._runner.run(CommandSpec(argv=tuple(argv), capture_output=False))

    def collect(self, target: MonitoringTarget) -> Path:
        _validate_target(target)
        container_result = self._runner.run(
            CommandSpec(argv=("docker", "ps", "--format", "{{.Names}}"))
        )
        name_pattern = re.compile(rf"^{re.escape(target.name_prefix)}-[0-9]+$")
        containers = sorted(
            (name for name in container_result.stdout.splitlines() if name_pattern.fullmatch(name)),
            key=_natural_name_key,
        )

        lines = [
            f"mtproxy_expected_containers {target.expected_count}",
            f"mtproxy_running_containers {len(containers)}",
        ]
        for container in containers:
            stats = self._container_stats(container)
            ready_targets = stats.get("total_ready_targets")
            if ready_targets is None:
                lines.append(f'mtproxy_scrape_success{{container="{container}"}} 0')
                continue
            lines.append(f'mtproxy_scrape_success{{container="{container}"}} 1')
            lines.append(
                f'mtproxy_stats_last_success_unixtime{{container="{container}"}} {int(time.time())}'
            )
            for metric_name in METRIC_NAMES:
                value = stats.get(metric_name)
                if value is not None:
                    lines.append(f'mtproxy_{metric_name}{{container="{container}"}} {value}')

        write_text_atomically(target.output_file, "\n".join(lines) + "\n", 0o644)
        return target.output_file

    def status(self, metrics_file: Path) -> MonitoringStatus:
        alloy_active = self._systemd_unit_active("alloy")
        timer_active = self._systemd_unit_active("mtproxy-stats-collector.timer")
        metrics_available = metrics_file.is_file() and metrics_file.stat().st_size > 0
        metrics_age_seconds = (
            max(0.0, time.time() - metrics_file.stat().st_mtime) if metrics_available else None
        )
        return MonitoringStatus(
            alloy_active=alloy_active,
            collector_timer_active=timer_active,
            metrics_file=metrics_file,
            metrics_available=metrics_available,
            metrics_age_seconds=metrics_age_seconds,
        )

    def target_from_state(self, state_path: Path, output_file: Path) -> MonitoringTarget:
        state = load_deployment_state(state_path)
        return MonitoringTarget(
            name_prefix=state.name_prefix,
            expected_count=state.port_range.count,
            output_file=output_file,
        )

    def _container_stats(self, container: str) -> dict[str, str]:
        command = CommandSpec(
            argv=(
                "docker",
                "exec",
                container,
                "bash",
                "-c",
                (
                    "exec 3<>/dev/tcp/127.0.0.1/2398; "
                    'printf "GET /stats HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n" >&3; '
                    "cat <&3"
                ),
            ),
            timeout_seconds=5,
            check=False,
        )
        try:
            result = self._runner.run(command)
        except CommandExecutionError:
            return {}
        if result.returncode != 0:
            return {}
        return parse_mtproxy_stats(result.stdout)

    def _systemd_unit_active(self, unit: str) -> bool:
        try:
            result = self._runner.run(
                CommandSpec(
                    argv=("systemctl", "is-active", "--quiet", unit),
                    check=False,
                )
            )
        except CommandExecutionError:
            return False
        return result.returncode == 0


def parse_mtproxy_stats(raw_stats: str) -> dict[str, str]:
    metrics: dict[str, str] = {}
    allowed_names = set(METRIC_NAMES)
    for line in raw_stats.replace("\r", "").splitlines():
        name, separator, value = line.partition("\t")
        if separator and name in allowed_names and NUMBER_PATTERN.fullmatch(value):
            metrics.setdefault(name, value)
    return metrics


def _validate_install_request(request: MonitoringInstallRequest) -> None:
    if HTTPS_URL_PATTERN.fullmatch(request.metrics_url) is None:
        raise MonitoringError("Metrics URL must be a valid HTTPS URL")
    if HTTPS_URL_PATTERN.fullmatch(request.logs_url) is None:
        raise MonitoringError("Logs URL must be a valid HTTPS URL")
    if USERNAME_PATTERN.fullmatch(request.metrics_user) is None:
        raise MonitoringError("Metrics username contains unsupported characters")
    if USERNAME_PATTERN.fullmatch(request.logs_user) is None:
        raise MonitoringError("Logs username contains unsupported characters")
    if not request.token_file.is_file() or request.token_file.is_symlink():
        raise MonitoringError(f"Token file is missing or unsafe: {request.token_file}")
    try:
        if not request.token_file.read_text().strip():
            raise MonitoringError("Token file is empty")
    except OSError as exc:
        raise MonitoringError(f"Unable to read token file: {request.token_file}") from exc
    if request.name_prefix is not None and NAME_PATTERN.fullmatch(request.name_prefix) is None:
        raise MonitoringError("Container prefix contains unsupported characters")
    if request.expected_count is not None and request.expected_count < 0:
        raise MonitoringError("Expected container count must be non-negative")


def _validate_target(target: MonitoringTarget) -> None:
    if NAME_PATTERN.fullmatch(target.name_prefix) is None:
        raise MonitoringError("Container prefix contains unsupported characters")
    if target.expected_count < 0:
        raise MonitoringError("Expected container count must be non-negative")


def _natural_name_key(value: str) -> tuple[str, int]:
    prefix, separator, suffix = value.rpartition("-")
    if not separator or not suffix.isdigit():
        return value, 0
    return prefix, int(suffix)
