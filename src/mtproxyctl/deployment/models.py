from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True, slots=True)
class ProjectPaths:
    root: Path

    @property
    def deploy_script(self) -> Path:
        return self.root / "script.bash"

    @property
    def monitoring_script(self) -> Path:
        return self.root / "monitoring-setup.bash"

    @property
    def minikube_script(self) -> Path:
        return self.root / "minikube-deployment.bash"


@dataclass(frozen=True, slots=True)
class DeploymentPlan:
    actions: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class ContainerStatus:
    name: str
    status: str
    expected: bool


@dataclass(frozen=True, slots=True)
class DeploymentStatus:
    state_path: Path
    expected_proxy_count: int
    running_proxy_count: int
    load_balancer_expected: bool
    load_balancer_running: bool
    containers: tuple[ContainerStatus, ...]

    @property
    def healthy(self) -> bool:
        proxy_healthy = self.running_proxy_count == self.expected_proxy_count
        load_balancer_healthy = not self.load_balancer_expected or self.load_balancer_running
        return proxy_healthy and load_balancer_healthy


@dataclass(frozen=True, slots=True)
class DoctorCheck:
    name: str
    healthy: bool
    detail: str
