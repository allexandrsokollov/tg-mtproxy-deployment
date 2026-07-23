from pathlib import Path

import pytest

from mtproxyctl.config.models import PullPolicy
from mtproxyctl.errors import ConfigurationError
from mtproxyctl.settings import load_app_settings


def test_dotenv_populates_nested_typed_settings(tmp_path: Path) -> None:
    env_file = tmp_path / ".env"
    env_file.write_text(
        "MTPROXYCTL_PROJECT_DIR=/srv/mtproxyctl\n"
        "MTPROXYCTL_DEPLOYMENT__PORT_RANGE=30000-30009\n"
        "MTPROXYCTL_DEPLOYMENT__LOAD_BALANCER_PORT=8443\n"
        "MTPROXYCTL_DEPLOYMENT__ENABLE_LOAD_BALANCER=false\n"
        "MTPROXYCTL_DEPLOYMENT__PULL_POLICY=never\n"
        "MTPROXYCTL_MONITORING__EXPECTED_COUNT=10\n"
        "UNRELATED_VARIABLE=is-ignored\n"
    )

    settings = load_app_settings(env_file)

    assert settings.project_dir == Path("/srv/mtproxyctl")
    assert settings.deployment.port_range == "30000-30009"
    assert settings.deployment.load_balancer_port == 8443
    assert settings.deployment.enable_load_balancer is False
    assert settings.deployment.pull_policy is PullPolicy.NEVER
    assert settings.monitoring.expected_count == 10


def test_environment_variable_overrides_dotenv(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    env_file = tmp_path / ".env"
    env_file.write_text("MTPROXYCTL_DEPLOYMENT__NAME_PREFIX=dotenv-prefix\n")
    monkeypatch.setenv("MTPROXYCTL_DEPLOYMENT__NAME_PREFIX", "environment-prefix")

    settings = load_app_settings(env_file)

    assert settings.deployment.name_prefix == "environment-prefix"


def test_invalid_dotenv_value_is_reported_as_configuration_error(tmp_path: Path) -> None:
    env_file = tmp_path / ".env"
    env_file.write_text("MTPROXYCTL_DEPLOYMENT__LOAD_BALANCER_PORT=invalid\n")

    with pytest.raises(ConfigurationError, match="Invalid application settings"):
        load_app_settings(env_file)
