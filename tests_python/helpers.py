from __future__ import annotations

from collections.abc import Callable
from pathlib import Path

from mtproxyctl.infrastructure.commands import CommandResult, CommandSpec


class RecordingRunner:
    def __init__(
        self,
        results: dict[tuple[str, ...], CommandResult] | None = None,
        responder: Callable[[CommandSpec], CommandResult] | None = None,
    ) -> None:
        self.results = results or {}
        self.commands: list[CommandSpec] = []
        self.responder = responder

    def run(self, command: CommandSpec) -> CommandResult:
        self.commands.append(command)
        if self.responder is not None:
            return self.responder(command)
        return self.results.get(
            command.argv,
            CommandResult(
                argv=command.argv,
                returncode=0,
                stdout="",
                stderr="",
            ),
        )


def write_deployment_fixture(workdir: Path) -> None:
    workdir.mkdir(parents=True, exist_ok=True)
    (workdir / "deployment.env").write_text(
        "FORMAT_VERSION=1\n"
        "PORT_RANGE=30000-30001\n"
        "PUBLIC_IP=203.0.113.10\n"
        "LB_PORT=8443\n"
        "NAME_PREFIX=proxy\n"
        "IMAGE=tg-mtproxy:local\n"
        "BUILD_LOCAL_IMAGE=yes\n"
        "MTPROXY_COMMIT=cafc3380a81671579ce366d0594b9a8e450827e9\n"
        "MTPROXY_PLATFORM=linux/amd64\n"
        "LB_NAME=mtproxy-lb\n"
        "LB_IMAGE=tg-mtproxy-nginx:local\n"
        "BUILD_LOCAL_LB_IMAGE=yes\n"
        "PULL_POLICY=missing\n"
        "PULL_RETRIES=3\n"
        "PULL_RETRY_DELAY=5\n"
        "USE_DD_SECRET=yes\n"
        "ENABLE_LB=yes\n"
    )
    (workdir / "mtproxy-secret").write_text("0123456789abcdef0123456789abcdef\n")
    (workdir / "proxy-secret").write_text("telegram-secret\n")
    (workdir / "proxy-multi.conf").write_text("telegram-config\n")
    (workdir / "nginx.conf").write_text("events {}\n")
    for path in workdir.iterdir():
        path.chmod(0o600)
    workdir.chmod(0o700)
