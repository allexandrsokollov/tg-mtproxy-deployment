from __future__ import annotations

from pathlib import Path

import pytest

from mtproxyctl.config.models import DeploymentRequest, PortRange
from mtproxyctl.deployment.models import ProjectPaths
from mtproxyctl.deployment.service import DeploymentService
from mtproxyctl.errors import ConfigurationError
from mtproxyctl.infrastructure.commands import CommandResult
from tests_python.helpers import RecordingRunner, write_deployment_fixture


def test_apply_passes_validated_arguments_without_secret_on_command_line(
    tmp_path: Path,
) -> None:
    project = tmp_path / "project"
    project.mkdir()
    script = project / "script.bash"
    script.write_text("#!/usr/bin/env bash\n")
    secret_file = tmp_path / "secret"
    secret = "0123456789abcdef0123456789abcdef"
    secret_file.write_text(f"{secret}\n")
    runner = RecordingRunner()
    service = DeploymentService(runner=runner, project_paths=ProjectPaths(project))
    workdir = tmp_path / "live"
    request = DeploymentRequest(
        port_range=PortRange(30000, 30001),
        workdir=workdir,
        public_ip="203.0.113.10",
        load_balancer_port=8443,
    )

    service.apply(request, secret_file=secret_file)

    command = runner.commands[0]
    assert command.argv[0] == str(script)
    assert "--secret" not in command.argv
    assert secret not in command.display()
    assert (workdir / "mtproxy-secret").read_text().strip() == secret
    assert (workdir / "mtproxy-secret").stat().st_mode & 0o777 == 0o600


def test_status_reports_missing_expected_container(tmp_path: Path) -> None:
    workdir = tmp_path / "live"
    write_deployment_fixture(workdir)
    docker_command = ("docker", "ps", "-a", "--format", "{{.Names}}\t{{.Status}}")
    runner = RecordingRunner(
        results={
            docker_command: CommandResult(
                argv=docker_command,
                returncode=0,
                stdout="proxy-1\tUp 10 minutes\nmtproxy-lb\tUp 10 minutes\n",
                stderr="",
            )
        }
    )
    service = DeploymentService(
        runner=runner,
        project_paths=ProjectPaths(tmp_path),
    )

    status = service.status(workdir / "deployment.env")

    assert status.running_proxy_count == 1
    assert status.expected_proxy_count == 2
    assert status.healthy is False
    assert any(
        container.name == "proxy-2" and container.status == "missing"
        for container in status.containers
    )


def test_status_reports_docker_inspection_failure_instead_of_false_missing_state(
    tmp_path: Path,
) -> None:
    workdir = tmp_path / "live"
    write_deployment_fixture(workdir)
    docker_command = ("docker", "ps", "-a", "--format", "{{.Names}}\t{{.Status}}")
    runner = RecordingRunner(
        results={
            docker_command: CommandResult(
                argv=docker_command,
                returncode=1,
                stdout="",
                stderr="permission denied",
            )
        }
    )
    service = DeploymentService(runner=runner, project_paths=ProjectPaths(tmp_path))

    with pytest.raises(ConfigurationError, match="permission denied"):
        service.status(workdir / "deployment.env")
