from pathlib import Path

import pytest

from mtproxyctl.cli import main


def test_deploy_plan_is_a_public_behavior_entry_point(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    exit_code = main(
        [
            "--project-dir",
            str(tmp_path),
            "deploy",
            "plan",
            "--port-range",
            "30000-30002",
            "--public-ip",
            "203.0.113.10",
            "--lb-port",
            "8443",
        ]
    )

    output = capsys.readouterr().out
    assert exit_code == 0
    assert "reconcile 3 proxy containers" in output
    assert "render and start mtproxy-lb on port 8443" in output


def test_cli_arguments_override_dotenv_defaults(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    env_file = tmp_path / ".env"
    env_file.write_text(
        "MTPROXYCTL_DEPLOYMENT__PORT_RANGE=30000-30009\n"
        "MTPROXYCTL_DEPLOYMENT__LOAD_BALANCER_PORT=8443\n"
    )

    exit_code = main(
        [
            "--env-file",
            str(env_file),
            "--project-dir",
            str(tmp_path),
            "deploy",
            "plan",
            "--port-range",
            "31000-31001",
            "--lb-port",
            "9443",
        ]
    )

    output = capsys.readouterr().out
    assert exit_code == 0
    assert "reconcile 2 proxy containers" in output
    assert "render and start mtproxy-lb on port 9443" in output


def test_dotenv_can_supply_required_deployment_port_range(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    env_file = tmp_path / ".env"
    env_file.write_text("MTPROXYCTL_DEPLOYMENT__PORT_RANGE=32000-32002\n")

    exit_code = main(
        [
            "--env-file",
            str(env_file),
            "--project-dir",
            str(tmp_path),
            "deploy",
            "plan",
        ]
    )

    output = capsys.readouterr().out
    assert exit_code == 0
    assert "reconcile 3 proxy containers" in output
