from pathlib import Path

from mtproxyctl.deployment.models import ProjectPaths
from mtproxyctl.minikube.models import MinikubeSetupRequest
from mtproxyctl.minikube.service import MinikubeService
from tests_python.helpers import RecordingRunner


def test_setup_runs_non_executable_compatibility_script_through_bash(
    tmp_path: Path,
) -> None:
    script = tmp_path / "minikube-deployment.bash"
    script.write_text("#!/usr/bin/env bash\n")
    script.chmod(0o600)
    runner = RecordingRunner()
    service = MinikubeService(runner=runner, project_paths=ProjectPaths(tmp_path))

    service.setup(
        MinikubeSetupRequest(
            profile="dev",
            kubernetes_version=None,
            cpus=4,
            memory_mb=8192,
            disk_size="30g",
            port_forward=None,
        )
    )

    assert runner.commands[0].argv[:2] == ("bash", str(script))
