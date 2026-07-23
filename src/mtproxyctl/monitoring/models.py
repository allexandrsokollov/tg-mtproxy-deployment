from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True, slots=True)
class MonitoringInstallRequest:
    metrics_url: str
    metrics_user: str
    logs_url: str
    logs_user: str
    token_file: Path
    deployment_state: Path | None
    name_prefix: str | None
    expected_count: int | None
    force: bool


@dataclass(frozen=True, slots=True)
class MonitoringTarget:
    name_prefix: str
    expected_count: int
    output_file: Path


@dataclass(frozen=True, slots=True)
class MonitoringStatus:
    alloy_active: bool
    collector_timer_active: bool
    metrics_file: Path
    metrics_available: bool
    metrics_age_seconds: float | None

    @property
    def healthy(self) -> bool:
        return self.alloy_active and self.collector_timer_active and self.metrics_available
