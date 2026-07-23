from __future__ import annotations

from dataclasses import asdict
from datetime import UTC, datetime
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import tarfile
import tempfile

from mtproxyctl import __version__
from mtproxyctl.backup.models import (
    BackupFile,
    BackupManifest,
    BackupPayload,
    BackupVerification,
)
from mtproxyctl.config.models import validate_secret
from mtproxyctl.config.state import load_deployment_state, parse_deployment_state
from mtproxyctl.errors import BackupError, ConfigurationError
from mtproxyctl.infrastructure.files import write_bytes_atomically

BACKUP_ROOT = "mtproxy-backup"
REQUIRED_FILES = (
    "deployment.env",
    "mtproxy-secret",
    "proxy-secret",
    "proxy-multi.conf",
)
OPTIONAL_FILES = ("nginx.conf", "docker-compose.yml")
MAX_FILE_SIZE = 16 * 1024 * 1024
MAX_ARCHIVE_CONTENT_SIZE = 48 * 1024 * 1024


class BackupService:
    def create(self, workdir: Path, backup_dir: Path) -> Path:
        state_path = workdir / "deployment.env"
        load_deployment_state(state_path)
        _validate_secret_path(workdir / "mtproxy-secret")
        source_files = self._source_files(workdir)
        manifest = _manifest_for_files(source_files)

        backup_dir.mkdir(parents=True, exist_ok=True)
        backup_dir.chmod(0o700)
        timestamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
        archive = backup_dir / f"mtproxy-{timestamp}-{os.getpid()}.tar.gz"
        descriptor, temporary_name = tempfile.mkstemp(
            dir=backup_dir,
            prefix=".backup.",
            suffix=".tar.gz",
        )
        os.close(descriptor)
        temporary_path = Path(temporary_name)
        try:
            with tarfile.open(temporary_path, mode="w:gz") as tar:
                _add_directory(tar, BACKUP_ROOT)
                _add_bytes(tar, f"{BACKUP_ROOT}/backup-version", b"2\n")
                manifest_json = json.dumps(
                    {
                        "format_version": manifest.format_version,
                        "created_at": manifest.created_at,
                        "application_version": manifest.application_version,
                        "files": [asdict(file) for file in manifest.files],
                    },
                    indent=2,
                    sort_keys=True,
                ).encode()
                _add_bytes(tar, f"{BACKUP_ROOT}/manifest.json", manifest_json)
                for path in source_files:
                    _add_bytes(tar, f"{BACKUP_ROOT}/{path.name}", path.read_bytes())
            temporary_path.chmod(0o600)
            os.replace(temporary_path, archive)
        except (OSError, tarfile.TarError) as exc:
            temporary_path.unlink(missing_ok=True)
            raise BackupError(f"Unable to create backup: {exc}") from exc
        return archive

    def verify(self, archive: Path) -> BackupVerification:
        return self._read_payload(archive).verification

    def restore(self, archive: Path, workdir: Path, force: bool) -> BackupVerification:
        payload = self._read_payload(archive)
        if (workdir / "deployment.env").exists() and not force:
            raise BackupError(
                f"Deployment already exists in {workdir}; pass --force to overwrite it"
            )

        workdir.mkdir(parents=True, exist_ok=True)
        workdir.chmod(0o700)
        for name, content in payload.files:
            write_bytes_atomically(workdir / name, content, 0o600)
        return payload.verification

    def list_archives(self, backup_dir: Path) -> tuple[Path, ...]:
        if not backup_dir.exists():
            return ()
        if not backup_dir.is_dir():
            raise BackupError(f"Backup path is not a directory: {backup_dir}")
        return tuple(
            sorted(
                backup_dir.glob("mtproxy-*.tar.gz"),
                key=lambda path: path.stat().st_mtime,
                reverse=True,
            )
        )

    def prune(self, backup_dir: Path, keep: int) -> tuple[Path, ...]:
        if keep < 0:
            raise BackupError("Backup retention count must be non-negative")
        archives = self.list_archives(backup_dir)
        removed = archives[keep:]
        for archive in removed:
            archive.unlink()
        return removed

    def _source_files(self, workdir: Path) -> tuple[Path, ...]:
        paths = [_validate_regular_file(workdir / name, required=True) for name in REQUIRED_FILES]
        for name in OPTIONAL_FILES:
            path = workdir / name
            if path.exists() or path.is_symlink():
                paths.append(_validate_regular_file(path, required=False))
        return tuple(paths)

    def _read_payload(self, archive: Path) -> BackupPayload:
        if not archive.is_file() or archive.is_symlink():
            raise BackupError(f"Backup archive is missing or unsafe: {archive}")
        try:
            with tarfile.open(archive, mode="r:gz") as tar:
                members = tar.getmembers()
                contents = _read_safe_members(tar, members)
        except (OSError, tarfile.TarError) as exc:
            raise BackupError(f"Unable to read backup archive: {archive}: {exc}") from exc

        version_bytes = contents.get("backup-version")
        if version_bytes is None:
            raise BackupError("Backup is missing backup-version")
        version = version_bytes.decode(errors="strict").strip()
        if version == "1":
            return _legacy_payload(archive, contents)
        if version != "2":
            raise BackupError(f"Unsupported backup format: {version}")
        return _version_two_payload(archive, contents)


def _manifest_for_files(paths: tuple[Path, ...]) -> BackupManifest:
    files = tuple(
        BackupFile(
            name=path.name,
            size=path.stat().st_size,
            sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
        )
        for path in paths
    )
    return BackupManifest(
        format_version=2,
        created_at=datetime.now(UTC).isoformat(),
        application_version=__version__,
        files=files,
    )


def _validate_secret_path(path: Path) -> None:
    safe_path = _validate_regular_file(path, required=True)
    try:
        validate_secret(safe_path.read_text())
    except (OSError, UnicodeDecodeError, ConfigurationError) as exc:
        raise BackupError(f"MTProxy secret is invalid: {path}") from exc


def _validate_regular_file(path: Path, required: bool) -> Path:
    if path.is_symlink() or not path.is_file():
        qualifier = "required" if required else "optional"
        raise BackupError(f"{qualifier.capitalize()} file is missing or unsafe: {path}")
    if path.stat().st_size > MAX_FILE_SIZE:
        raise BackupError(f"Deployment file is too large to back up safely: {path}")
    return path


def _add_directory(tar: tarfile.TarFile, name: str) -> None:
    info = tarfile.TarInfo(name)
    info.type = tarfile.DIRTYPE
    info.mode = 0o700
    info.mtime = int(datetime.now(UTC).timestamp())
    tar.addfile(info)


def _add_bytes(tar: tarfile.TarFile, name: str, content: bytes) -> None:
    info = tarfile.TarInfo(name)
    info.size = len(content)
    info.mode = 0o600
    info.mtime = int(datetime.now(UTC).timestamp())
    tar.addfile(info, io.BytesIO(content))


def _read_safe_members(
    tar: tarfile.TarFile,
    members: list[tarfile.TarInfo],
) -> dict[str, bytes]:
    allowed = {
        "backup-version",
        "manifest.json",
        *REQUIRED_FILES,
        *OPTIONAL_FILES,
    }
    contents: dict[str, bytes] = {}
    total_size = 0
    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts:
            raise BackupError(f"Backup contains an unsafe path: {member.name}")
        if member.name.rstrip("/") == BACKUP_ROOT and member.isdir():
            continue
        if len(path.parts) != 2 or path.parts[0] != BACKUP_ROOT:
            raise BackupError(f"Backup contains an unexpected path: {member.name}")
        name = path.parts[1]
        if name not in allowed or name in contents:
            raise BackupError(f"Backup contains an unexpected or duplicate file: {member.name}")
        if not member.isfile() or member.issym() or member.islnk():
            raise BackupError(f"Backup member is not a regular file: {member.name}")
        if member.size < 0 or member.size > MAX_FILE_SIZE:
            raise BackupError(f"Backup member has an unsafe size: {member.name}")
        total_size += member.size
        if total_size > MAX_ARCHIVE_CONTENT_SIZE:
            raise BackupError("Backup archive expands beyond the safe size limit")
        extracted = tar.extractfile(member)
        if extracted is None:
            raise BackupError(f"Unable to read backup member: {member.name}")
        content = extracted.read(MAX_FILE_SIZE + 1)
        if len(content) != member.size:
            raise BackupError(f"Backup member size does not match its header: {member.name}")
        contents[name] = content
    return contents


def _legacy_payload(archive: Path, contents: dict[str, bytes]) -> BackupPayload:
    _validate_payload_files(contents)
    files = tuple(
        BackupFile(name=name, size=len(contents[name]), sha256=_sha256(contents[name]))
        for name in (*REQUIRED_FILES, *OPTIONAL_FILES)
        if name in contents
    )
    manifest = BackupManifest(
        format_version=1,
        created_at=datetime.fromtimestamp(archive.stat().st_mtime, tz=UTC).isoformat(),
        application_version="legacy",
        files=files,
    )
    return BackupPayload(
        verification=BackupVerification(archive=archive, manifest=manifest, legacy=True),
        files=tuple((file.name, contents[file.name]) for file in files),
    )


def _version_two_payload(archive: Path, contents: dict[str, bytes]) -> BackupPayload:
    _validate_payload_files(contents)
    manifest_bytes = contents.get("manifest.json")
    if manifest_bytes is None:
        raise BackupError("Version 2 backup is missing manifest.json")
    manifest = _parse_manifest(manifest_bytes)
    actual_names = {name for name in contents if name not in {"backup-version", "manifest.json"}}
    expected_names = {file.name for file in manifest.files}
    if actual_names != expected_names:
        raise BackupError("Backup contents do not match the manifest")
    for file in manifest.files:
        content = contents[file.name]
        if len(content) != file.size or _sha256(content) != file.sha256:
            raise BackupError(f"Backup checksum verification failed: {file.name}")
    return BackupPayload(
        verification=BackupVerification(archive=archive, manifest=manifest, legacy=False),
        files=tuple((file.name, contents[file.name]) for file in manifest.files),
    )


def _validate_payload_files(contents: dict[str, bytes]) -> None:
    missing = [name for name in REQUIRED_FILES if name not in contents]
    if missing:
        raise BackupError(f"Backup is missing required files: {', '.join(missing)}")
    try:
        validate_secret(contents["mtproxy-secret"].decode())
        parse_deployment_state(contents["deployment.env"].decode(), Path("/restored"))
    except (UnicodeDecodeError, ConfigurationError) as exc:
        raise BackupError(
            "Backup contains invalid deployment state or an invalid MTProxy secret"
        ) from exc


def _parse_manifest(content: bytes) -> BackupManifest:
    try:
        raw: object = json.loads(content)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BackupError("Backup manifest is not valid JSON") from exc
    if not isinstance(raw, dict):
        raise BackupError("Backup manifest must be a JSON object")
    format_version = raw.get("format_version")
    created_at = raw.get("created_at")
    application_version = raw.get("application_version")
    raw_files = raw.get("files")
    if (
        format_version != 2
        or not isinstance(created_at, str)
        or not isinstance(application_version, str)
        or not isinstance(raw_files, list)
    ):
        raise BackupError("Backup manifest has invalid metadata")
    files: list[BackupFile] = []
    seen_names: set[str] = set()
    for raw_file in raw_files:
        if not isinstance(raw_file, dict):
            raise BackupError("Backup manifest contains an invalid file entry")
        name = raw_file.get("name")
        size = raw_file.get("size")
        sha256 = raw_file.get("sha256")
        mode = raw_file.get("mode")
        if (
            not isinstance(name, str)
            or name not in {*REQUIRED_FILES, *OPTIONAL_FILES}
            or name in seen_names
            or not isinstance(size, int)
            or isinstance(size, bool)
            or not 0 <= size <= MAX_FILE_SIZE
            or not isinstance(sha256, str)
            or len(sha256) != 64
            or not isinstance(mode, int)
            or isinstance(mode, bool)
            or mode != 0o600
        ):
            raise BackupError("Backup manifest contains an invalid file entry")
        seen_names.add(name)
        files.append(BackupFile(name=name, size=size, sha256=sha256, mode=mode))
    return BackupManifest(
        format_version=2,
        created_at=created_at,
        application_version=application_version,
        files=tuple(files),
    )


def _sha256(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()
