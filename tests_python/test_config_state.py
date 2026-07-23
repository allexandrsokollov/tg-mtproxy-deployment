from pathlib import Path

import pytest

from mtproxyctl.config.models import PortRange
from mtproxyctl.config.state import load_deployment_state
from mtproxyctl.errors import ConfigurationError
from tests_python.helpers import write_deployment_fixture


def test_load_deployment_state_returns_typed_validated_contract(tmp_path: Path) -> None:
    workdir = tmp_path / "live"
    write_deployment_fixture(workdir)

    state = load_deployment_state(workdir / "deployment.env")

    assert state.port_range == PortRange(start=30000, end=30001)
    assert state.name_prefix == "proxy"
    assert state.enable_load_balancer is True
    assert state.workdir == workdir


def test_load_deployment_state_rejects_unknown_executable_value(tmp_path: Path) -> None:
    workdir = tmp_path / "live"
    write_deployment_fixture(workdir)
    state_path = workdir / "deployment.env"
    state_path.write_text(state_path.read_text() + "UNRELATED=$(touch /tmp/unsafe)\n")

    with pytest.raises(ConfigurationError, match="Invalid or duplicate"):
        load_deployment_state(state_path)


def test_port_range_rejects_reversed_ports() -> None:
    with pytest.raises(ConfigurationError, match="less than or equal"):
        PortRange.parse("4001-4000")
