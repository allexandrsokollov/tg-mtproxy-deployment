from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class PortForwardRequest:
    namespace: str
    service: str
    local_port: int
    remote_port: int


@dataclass(frozen=True, slots=True)
class MinikubeSetupRequest:
    profile: str
    kubernetes_version: str | None
    cpus: int
    memory_mb: int
    disk_size: str
    port_forward: PortForwardRequest | None
