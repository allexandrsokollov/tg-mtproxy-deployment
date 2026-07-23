from __future__ import annotations

import re

from mtproxyctl.deployment.models import ProjectPaths
from mtproxyctl.errors import ConfigurationError
from mtproxyctl.infrastructure.commands import CommandRunner, CommandSpec
from mtproxyctl.minikube.models import MinikubeSetupRequest

SAFE_NAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
DISK_SIZE_PATTERN = re.compile(r"^[1-9][0-9]*(?:[gGmM])$")


class MinikubeService:
    def __init__(self, runner: CommandRunner, project_paths: ProjectPaths) -> None:
        self._runner = runner
        self._project_paths = project_paths

    def setup(self, request: MinikubeSetupRequest) -> None:
        _validate_request(request)
        script = self._project_paths.minikube_script
        if not script.is_file():
            raise ConfigurationError(f"Minikube setup script is missing: {script}")
        argv = [
            str(script),
            "--profile",
            request.profile,
            "--cpus",
            str(request.cpus),
            "--memory",
            str(request.memory_mb),
            "--disk-size",
            request.disk_size,
        ]
        if request.kubernetes_version is not None:
            argv.extend(("--k8s-version", request.kubernetes_version))
        if request.port_forward is not None:
            argv.extend(
                (
                    "--pf-namespace",
                    request.port_forward.namespace,
                    "--pf-service",
                    request.port_forward.service,
                    "--pf-local-port",
                    str(request.port_forward.local_port),
                    "--pf-remote-port",
                    str(request.port_forward.remote_port),
                )
            )
        self._runner.run(CommandSpec(argv=tuple(argv), capture_output=False))

    def status(self, profile: str) -> str:
        if SAFE_NAME_PATTERN.fullmatch(profile) is None:
            raise ConfigurationError("Minikube profile contains unsupported characters")
        result = self._runner.run(CommandSpec(argv=("minikube", "status", "--profile", profile)))
        return result.stdout


def _validate_request(request: MinikubeSetupRequest) -> None:
    if SAFE_NAME_PATTERN.fullmatch(request.profile) is None:
        raise ConfigurationError("Minikube profile contains unsupported characters")
    if request.cpus < 1 or request.memory_mb < 512:
        raise ConfigurationError("Minikube requires at least 1 CPU and 512 MB of memory")
    if DISK_SIZE_PATTERN.fullmatch(request.disk_size) is None:
        raise ConfigurationError("Disk size must look like 30g or 10240m")
    if request.port_forward is None:
        return
    if SAFE_NAME_PATTERN.fullmatch(request.port_forward.namespace) is None:
        raise ConfigurationError("Kubernetes namespace contains unsupported characters")
    if SAFE_NAME_PATTERN.fullmatch(request.port_forward.service) is None:
        raise ConfigurationError("Kubernetes service contains unsupported characters")
    for port in (
        request.port_forward.local_port,
        request.port_forward.remote_port,
    ):
        if not 1 <= port <= 65_535:
            raise ConfigurationError("Port-forward ports must be between 1 and 65535")
