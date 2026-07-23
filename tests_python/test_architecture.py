from dataclasses import is_dataclass

from mtproxyctl.backup.service import BackupService
from mtproxyctl.deployment.service import DeploymentService
from mtproxyctl.infrastructure.commands import SubprocessCommandRunner
from mtproxyctl.minikube.service import MinikubeService
from mtproxyctl.monitoring.service import MonitoringService
from tests_python.helpers import RecordingRunner


def test_behavioral_classes_are_not_dataclasses() -> None:
    behavioral_classes = (
        BackupService,
        DeploymentService,
        MonitoringService,
        MinikubeService,
        SubprocessCommandRunner,
        RecordingRunner,
    )

    assert all(not is_dataclass(behavioral_class) for behavioral_class in behavioral_classes)
