from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
import ipaddress
from pathlib import Path
import re

from mtproxyctl.errors import ConfigurationError

NAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
IMAGE_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/:@-]*$")
PLATFORM_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_./-]*$")
COMMIT_PATTERN = re.compile(r"^[0-9a-fA-F]{40}$")
SECRET_PATTERN = re.compile(r"^[0-9a-fA-F]{32}$")


class PullPolicy(StrEnum):
    MISSING = "missing"
    ALWAYS = "always"
    NEVER = "never"


@dataclass(frozen=True, slots=True)
class PortRange:
    start: int
    end: int

    def __post_init__(self) -> None:
        if not 1 <= self.start <= 65_535 or not 1 <= self.end <= 65_535:
            raise ConfigurationError("Ports must be between 1 and 65535")
        if self.start > self.end:
            raise ConfigurationError("Port range start must be less than or equal to end")

    @classmethod
    def parse(cls, value: str) -> PortRange:
        match = re.fullmatch(r"([0-9]+)-([0-9]+)", value)
        if match is None:
            raise ConfigurationError("Port range must use START-END format")
        return cls(start=int(match.group(1)), end=int(match.group(2)))

    @property
    def count(self) -> int:
        return self.end - self.start + 1

    def __str__(self) -> str:
        return f"{self.start}-{self.end}"


@dataclass(frozen=True, slots=True)
class DeploymentState:
    port_range: PortRange
    public_ip: str
    load_balancer_port: int
    name_prefix: str
    proxy_image: str
    build_local_proxy_image: bool
    mtproxy_commit: str
    mtproxy_platform: str
    load_balancer_name: str
    load_balancer_image: str
    build_local_load_balancer_image: bool
    pull_policy: PullPolicy
    pull_retries: int
    pull_retry_delay: int
    use_dd_secret: bool
    enable_load_balancer: bool
    workdir: Path

    def __post_init__(self) -> None:
        _validate_ipv4(self.public_ip)
        _validate_port(self.load_balancer_port, "Load balancer port")
        if (
            self.enable_load_balancer
            and self.port_range.start <= self.load_balancer_port <= self.port_range.end
        ):
            raise ConfigurationError("Load balancer port conflicts with proxy port range")
        _validate_pattern(self.name_prefix, NAME_PATTERN, "Proxy name prefix")
        _validate_pattern(self.load_balancer_name, NAME_PATTERN, "Load balancer name")
        _validate_pattern(self.proxy_image, IMAGE_PATTERN, "Proxy image")
        _validate_pattern(self.load_balancer_image, IMAGE_PATTERN, "Load balancer image")
        _validate_pattern(self.mtproxy_platform, PLATFORM_PATTERN, "MTProxy platform")
        _validate_pattern(self.mtproxy_commit, COMMIT_PATTERN, "MTProxy commit")
        if self.pull_retries < 0 or self.pull_retry_delay < 0:
            raise ConfigurationError("Pull retries and delay must be non-negative")


@dataclass(frozen=True, slots=True)
class DeploymentRequest:
    port_range: PortRange
    workdir: Path
    public_ip: str | None = None
    load_balancer_port: int = 443
    name_prefix: str = "mtproxy"
    proxy_image: str = "tg-mtproxy:local"
    build_local_proxy_image: bool = True
    mtproxy_commit: str = "cafc3380a81671579ce366d0594b9a8e450827e9"
    load_balancer_name: str = "mtproxy-lb"
    load_balancer_image: str = "tg-mtproxy-nginx:local"
    build_local_load_balancer_image: bool = True
    pull_policy: PullPolicy = PullPolicy.MISSING
    pull_retries: int = 3
    pull_retry_delay: int = 5
    use_dd_secret: bool = True
    enable_load_balancer: bool = True
    mtproxy_platform: str = "linux/amd64"

    def validate(self) -> None:
        if self.public_ip is not None:
            _validate_ipv4(self.public_ip)
        _validate_port(self.load_balancer_port, "Load balancer port")
        if (
            self.enable_load_balancer
            and self.port_range.start <= self.load_balancer_port <= self.port_range.end
        ):
            raise ConfigurationError("Load balancer port conflicts with proxy port range")
        _validate_pattern(self.name_prefix, NAME_PATTERN, "Proxy name prefix")
        _validate_pattern(self.load_balancer_name, NAME_PATTERN, "Load balancer name")
        _validate_pattern(self.proxy_image, IMAGE_PATTERN, "Proxy image")
        _validate_pattern(self.load_balancer_image, IMAGE_PATTERN, "Load balancer image")
        _validate_pattern(self.mtproxy_platform, PLATFORM_PATTERN, "MTProxy platform")
        _validate_pattern(self.mtproxy_commit, COMMIT_PATTERN, "MTProxy commit")
        if self.pull_retries < 0 or self.pull_retry_delay < 0:
            raise ConfigurationError("Pull retries and delay must be non-negative")


def validate_secret(secret: str) -> str:
    normalized = secret.strip()
    if normalized.lower().startswith("dd") and len(normalized) == 34:
        normalized = normalized[2:]
    if SECRET_PATTERN.fullmatch(normalized) is None:
        raise ConfigurationError("MTProxy secret must contain exactly 32 hexadecimal characters")
    return normalized.lower()


def _validate_ipv4(value: str) -> None:
    try:
        address = ipaddress.ip_address(value)
    except ValueError as exc:
        raise ConfigurationError(f"Invalid public IPv4 address: {value}") from exc
    if address.version != 4:
        raise ConfigurationError(f"Public address must be IPv4: {value}")


def _validate_port(value: int, label: str) -> None:
    if not 1 <= value <= 65_535:
        raise ConfigurationError(f"{label} must be between 1 and 65535")


def _validate_pattern(value: str, pattern: re.Pattern[str], label: str) -> None:
    if pattern.fullmatch(value) is None:
        raise ConfigurationError(f"{label} contains unsupported characters: {value}")
