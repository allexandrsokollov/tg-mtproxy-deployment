from __future__ import annotations

from pathlib import Path

from pydantic import BaseModel, ConfigDict, Field, ValidationError
from pydantic_settings import BaseSettings, SettingsConfigDict, SettingsError

from mtproxyctl.config.models import PullPolicy
from mtproxyctl.errors import ConfigurationError

DEFAULT_MTPROXY_COMMIT = "cafc3380a81671579ce366d0594b9a8e450827e9"


class SettingsSection(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


class DeploymentSettings(SettingsSection):
    port_range: str | None = Field(default=None, pattern=r"^[0-9]+-[0-9]+$")
    workdir: Path = Field(default_factory=lambda: Path.home() / "mtproxy")
    public_ip: str | None = None
    load_balancer_port: int = Field(default=443, ge=1, le=65_535)
    name_prefix: str = "mtproxy"
    proxy_image: str = "tg-mtproxy:local"
    build_local_proxy_image: bool = True
    mtproxy_commit: str = DEFAULT_MTPROXY_COMMIT
    mtproxy_platform: str = "linux/amd64"
    load_balancer_name: str = "mtproxy-lb"
    load_balancer_image: str = "tg-mtproxy-nginx:local"
    build_local_load_balancer_image: bool = True
    pull_policy: PullPolicy = PullPolicy.MISSING
    pull_retries: int = Field(default=3, ge=0)
    pull_retry_delay: int = Field(default=5, ge=0)
    use_dd_secret: bool = True
    enable_load_balancer: bool = True
    secret_file: Path | None = None


class BackupSettings(SettingsSection):
    backup_dir: Path | None = None


class MonitoringSettings(SettingsSection):
    metrics_url: str | None = None
    metrics_user: str | None = None
    logs_url: str | None = None
    logs_user: str | None = None
    token_file: Path | None = None
    deployment_state: Path | None = None
    name_prefix: str | None = None
    expected_count: int | None = Field(default=None, ge=0)
    metrics_file: Path = Path("/var/lib/alloy/textfile/mtproxy.prom")


class MinikubeSettings(SettingsSection):
    profile: str = "minikube"
    kubernetes_version: str | None = None
    cpus: int = Field(default=4, ge=1)
    memory_mb: int = Field(default=8192, ge=512)
    disk_size: str = Field(default="30g", pattern=r"^[1-9][0-9]*(?:[gGmM])$")
    port_forward_namespace: str | None = None
    port_forward_service: str | None = None
    port_forward_local_port: int | None = Field(default=None, ge=1, le=65_535)
    port_forward_remote_port: int | None = Field(default=None, ge=1, le=65_535)


class AppSettings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        env_prefix="MTPROXYCTL_",
        env_nested_delimiter="__",
        env_nested_max_split=1,
        nested_model_default_partial_update=True,
        env_ignore_empty=True,
        extra="ignore",
        frozen=True,
    )

    project_dir: Path | None = None
    deployment: DeploymentSettings = Field(default_factory=DeploymentSettings)
    backup: BackupSettings = Field(default_factory=BackupSettings)
    monitoring: MonitoringSettings = Field(default_factory=MonitoringSettings)
    minikube: MinikubeSettings = Field(default_factory=MinikubeSettings)


def load_app_settings(env_file: Path | None = Path(".env")) -> AppSettings:
    try:
        return AppSettings(_env_file=env_file)
    except (SettingsError, ValidationError) as exc:
        raise ConfigurationError(f"Invalid application settings: {exc}") from exc
