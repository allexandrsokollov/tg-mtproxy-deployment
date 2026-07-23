from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True, slots=True)
class BackupFile:
    name: str
    size: int
    sha256: str
    mode: int = 0o600


@dataclass(frozen=True, slots=True)
class BackupManifest:
    format_version: int
    created_at: str
    application_version: str
    files: tuple[BackupFile, ...]


@dataclass(frozen=True, slots=True)
class BackupVerification:
    archive: Path
    manifest: BackupManifest
    legacy: bool


@dataclass(frozen=True, slots=True)
class BackupPayload:
    verification: BackupVerification
    files: tuple[tuple[str, bytes], ...]
