from __future__ import annotations

import io
import os
from pathlib import Path
import subprocess
import tarfile

import pytest

from mtproxyctl.backup.service import BackupService
from mtproxyctl.errors import BackupError
from tests_python.helpers import write_deployment_fixture


def test_backup_verify_restore_round_trip_preserves_protected_state(tmp_path: Path) -> None:
    source = tmp_path / "source"
    backup_dir = tmp_path / "backups"
    restored = tmp_path / "restored"
    write_deployment_fixture(source)
    service = BackupService()

    archive = service.create(source, backup_dir)
    verification = service.verify(archive)
    service.restore(archive, restored, force=False)

    assert verification.manifest.format_version == 2
    assert {file.name for file in verification.manifest.files} >= {
        "deployment.env",
        "mtproxy-secret",
        "proxy-secret",
        "proxy-multi.conf",
    }
    assert (restored / "deployment.env").read_bytes() == (source / "deployment.env").read_bytes()
    assert (restored / "mtproxy-secret").stat().st_mode & 0o777 == 0o600
    assert restored.stat().st_mode & 0o777 == 0o700


def test_restore_refuses_existing_deployment_without_force(tmp_path: Path) -> None:
    source = tmp_path / "source"
    restored = tmp_path / "restored"
    write_deployment_fixture(source)
    write_deployment_fixture(restored)
    service = BackupService()
    archive = service.create(source, tmp_path / "backups")

    with pytest.raises(BackupError, match="pass --force"):
        service.restore(archive, restored, force=False)


def test_verify_rejects_archive_path_traversal(tmp_path: Path) -> None:
    archive = tmp_path / "unsafe.tar.gz"
    content = b"escape"
    with tarfile.open(archive, mode="w:gz") as tar:
        member = tarfile.TarInfo("../../escape")
        member.size = len(content)
        tar.addfile(member, io.BytesIO(content))

    with pytest.raises(BackupError, match="unsafe path"):
        BackupService().verify(archive)


def test_backup_rejects_symlinked_required_file(tmp_path: Path) -> None:
    source = tmp_path / "source"
    write_deployment_fixture(source)
    secret = source / "proxy-secret"
    secret.unlink()
    secret.symlink_to(source / "mtproxy-secret")

    with pytest.raises(BackupError, match="unsafe"):
        BackupService().create(source, tmp_path / "backups")


def test_verify_rejects_invalid_persisted_deployment_state(tmp_path: Path) -> None:
    source = tmp_path / "source"
    write_deployment_fixture(source)
    archive = BackupService().create(source, tmp_path / "backups")
    invalid_archive = tmp_path / "invalid-state.tar.gz"

    with (
        tarfile.open(archive, mode="r:gz") as original,
        tarfile.open(invalid_archive, mode="w:gz") as modified,
    ):
        for member in original.getmembers():
            extracted = original.extractfile(member) if member.isfile() else None
            content = extracted.read() if extracted is not None else b""
            if member.name == "mtproxy-backup/deployment.env":
                content += b"UNEXPECTED=value\n"
                member.size = len(content)
            modified.addfile(member, io.BytesIO(content) if member.isfile() else None)

    with pytest.raises(BackupError, match="invalid"):
        BackupService().verify(invalid_archive)


def test_verify_reads_archive_created_by_legacy_backup_script(tmp_path: Path) -> None:
    source = tmp_path / "source"
    backup_dir = tmp_path / "backups"
    write_deployment_fixture(source)
    project_dir = Path(__file__).resolve().parents[1]

    completed = subprocess.run(
        (
            str(project_dir / "backup.bash"),
            "backup",
            "--workdir",
            str(source),
            "--backup-dir",
            str(backup_dir),
        ),
        check=True,
        capture_output=True,
        text=True,
        env={
            **os.environ,
            "COPYFILE_DISABLE": "1",
            "COPY_EXTENDED_ATTRIBUTES_DISABLE": "1",
        },
    )
    archive_line = next(
        line for line in completed.stdout.splitlines() if line.startswith("[*] Backup created: ")
    )
    archive = Path(archive_line.removeprefix("[*] Backup created: "))

    verification = BackupService().verify(archive)

    assert verification.legacy is True
    assert verification.manifest.format_version == 1
    assert {file.name for file in verification.manifest.files} >= {
        "deployment.env",
        "mtproxy-secret",
    }
