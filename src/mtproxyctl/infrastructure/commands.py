from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import shlex
import subprocess
from typing import Protocol

from mtproxyctl.errors import CommandExecutionError


@dataclass(frozen=True, slots=True)
class CommandSpec:
    argv: tuple[str, ...]
    cwd: Path | None = None
    environment: tuple[tuple[str, str], ...] = ()
    capture_output: bool = True
    timeout_seconds: float | None = None
    check: bool = True
    sensitive_values: tuple[str, ...] = ()

    def display(self) -> str:
        rendered = shlex.join(self.argv)
        for value in self.sensitive_values:
            if value:
                rendered = rendered.replace(value, "***")
        return rendered


@dataclass(frozen=True, slots=True)
class CommandResult:
    argv: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str
    skipped: bool = False


class CommandRunner(Protocol):
    def run(self, command: CommandSpec) -> CommandResult:
        """Execute one external command."""


class SubprocessCommandRunner:
    __slots__ = ("_dry_run",)

    def __init__(self, dry_run: bool = False) -> None:
        self._dry_run = dry_run

    def run(self, command: CommandSpec) -> CommandResult:
        if not command.argv:
            raise ValueError("Command argv must not be empty")

        if self._dry_run:
            return CommandResult(
                argv=command.argv,
                returncode=0,
                stdout="",
                stderr="",
                skipped=True,
            )

        environment = os.environ.copy()
        environment.update(command.environment)
        try:
            completed = subprocess.run(
                command.argv,
                cwd=command.cwd,
                env=environment,
                capture_output=command.capture_output,
                text=True,
                timeout=command.timeout_seconds,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise CommandExecutionError(
                f"Unable to run command: {command.display()}: {exc}"
            ) from exc

        result = CommandResult(
            argv=command.argv,
            returncode=completed.returncode,
            stdout=completed.stdout or "",
            stderr=completed.stderr or "",
        )
        if command.check and result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip() or "no command output"
            raise CommandExecutionError(
                f"Command failed ({result.returncode}): {command.display()}: {detail}"
            )
        return result
