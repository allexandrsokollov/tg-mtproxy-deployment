from __future__ import annotations

from pathlib import Path
import re
import shutil

from mtproxyctl.config.models import (
    DeploymentRequest,
    DeploymentState,
    validate_secret,
)
from mtproxyctl.config.state import load_deployment_state
from mtproxyctl.deployment.models import (
    ContainerStatus,
    DeploymentPlan,
    DeploymentStatus,
    DoctorCheck,
    ProjectPaths,
)
from mtproxyctl.errors import CommandExecutionError, ConfigurationError
from mtproxyctl.infrastructure.commands import CommandRunner, CommandSpec
from mtproxyctl.infrastructure.files import write_text_atomically


class DeploymentService:
    def __init__(self, runner: CommandRunner, project_paths: ProjectPaths) -> None:
        self._runner = runner
        self._project_paths = project_paths

    def plan(self, request: DeploymentRequest) -> DeploymentPlan:
        request.validate()
        actions = [
            "validate the host, deployment settings, and required privileges",
            "install or verify Docker and host dependencies",
            "build or pull all required container images before replacement",
            "create or retain protected Telegram runtime and secret files",
            (
                f"reconcile {request.port_range.count} proxy containers "
                f"named {request.name_prefix}-1..{request.name_prefix}-{request.port_range.count}"
            ),
        ]
        if request.enable_load_balancer:
            actions.append(
                f"render and start {request.load_balancer_name} on port "
                f"{request.load_balancer_port}"
            )
        else:
            actions.append("remove the previously managed load balancer if present")
        actions.extend(
            (
                "install the daily Telegram configuration refresh schedule",
                f"persist non-secret deployment state under {request.workdir}",
            )
        )
        return DeploymentPlan(actions=tuple(actions))

    def apply(
        self,
        request: DeploymentRequest,
        secret_file: Path | None = None,
    ) -> None:
        request.validate()
        self._require_script(self._project_paths.deploy_script)
        if secret_file is not None:
            self._install_secret(request.workdir, secret_file)
        self._runner.run(
            CommandSpec(
                argv=self._deployment_argv(request),
                environment=(
                    ("LB_NAME", request.load_balancer_name),
                    ("MTPROXY_PLATFORM", request.mtproxy_platform),
                    ("PULL_RETRY_DELAY", str(request.pull_retry_delay)),
                ),
                capture_output=False,
            )
        )

    def redeploy(self, state_path: Path) -> None:
        state = load_deployment_state(state_path)
        self.apply(_request_from_state(state))

    def status(self, state_path: Path) -> DeploymentStatus:
        state = load_deployment_state(state_path)
        expected_names = {
            f"{state.name_prefix}-{index}" for index in range(1, state.port_range.count + 1)
        }
        try:
            result = self._runner.run(
                CommandSpec(
                    argv=("docker", "ps", "-a", "--format", "{{.Names}}\t{{.Status}}"),
                    check=False,
                )
            )
        except CommandExecutionError as exc:
            raise ConfigurationError(f"Unable to inspect Docker containers: {exc}") from exc
        if result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip() or "no command output"
            raise ConfigurationError(f"Docker container inspection failed: {detail}")

        containers: list[ContainerStatus] = []
        running_proxy_count = 0
        load_balancer_running = False
        for line in result.stdout.splitlines():
            name, separator, status = line.partition("\t")
            if not separator:
                continue
            is_expected_proxy = name in expected_names
            is_load_balancer = name == state.load_balancer_name
            if not is_expected_proxy and not is_load_balancer:
                continue
            is_running = status.lower().startswith("up ")
            if is_expected_proxy and is_running:
                running_proxy_count += 1
            if is_load_balancer and is_running:
                load_balancer_running = True
            containers.append(
                ContainerStatus(
                    name=name,
                    status=status,
                    expected=True,
                )
            )

        observed_names = {container.name for container in containers}
        containers.extend(
            ContainerStatus(name=missing_name, status="missing", expected=True)
            for missing_name in sorted(
                expected_names - observed_names,
                key=_natural_name_key,
            )
        )
        if state.enable_load_balancer and state.load_balancer_name not in observed_names:
            containers.append(
                ContainerStatus(
                    name=state.load_balancer_name,
                    status="missing",
                    expected=True,
                )
            )

        return DeploymentStatus(
            state_path=state_path,
            expected_proxy_count=state.port_range.count,
            running_proxy_count=running_proxy_count,
            load_balancer_expected=state.enable_load_balancer,
            load_balancer_running=load_balancer_running,
            containers=tuple(sorted(containers, key=lambda item: _natural_name_key(item.name))),
        )

    def doctor(self) -> tuple[DoctorCheck, ...]:
        checks = [
            DoctorCheck(
                name="python",
                healthy=True,
                detail="Python runtime is available",
            )
        ]
        for command in ("bash", "curl", "docker"):
            location = shutil.which(command)
            checks.append(
                DoctorCheck(
                    name=command,
                    healthy=location is not None,
                    detail=location or f"{command} was not found on PATH",
                )
            )
        for label, path in (
            ("deployment script", self._project_paths.deploy_script),
            ("monitoring script", self._project_paths.monitoring_script),
            ("Minikube script", self._project_paths.minikube_script),
        ):
            checks.append(
                DoctorCheck(
                    name=label,
                    healthy=path.is_file(),
                    detail=str(path),
                )
            )
        return tuple(checks)

    def _deployment_argv(self, request: DeploymentRequest) -> tuple[str, ...]:
        argv = [
            str(self._project_paths.deploy_script),
            "--port-range",
            str(request.port_range),
            "--lb-port",
            str(request.load_balancer_port),
            "--prefix",
            request.name_prefix,
            "--workdir",
            str(request.workdir),
            "--image",
            request.proxy_image,
            "--build-local-image",
            _yes_no(request.build_local_proxy_image),
            "--mtproxy-commit",
            request.mtproxy_commit,
            "--lb-image",
            request.load_balancer_image,
            "--build-local-lb",
            _yes_no(request.build_local_load_balancer_image),
            "--pull-policy",
            request.pull_policy.value,
            "--pull-retries",
            str(request.pull_retries),
            "--dd-secret",
            _yes_no(request.use_dd_secret),
            "--enable-lb",
            _yes_no(request.enable_load_balancer),
        ]
        if request.public_ip is not None:
            argv.extend(("--public-ip", request.public_ip))
        return tuple(argv)

    def _install_secret(self, workdir: Path, source: Path) -> None:
        if not source.is_file() or source.is_symlink():
            raise ConfigurationError(f"Secret file is missing or unsafe: {source}")
        try:
            secret = validate_secret(source.read_text())
        except OSError as exc:
            raise ConfigurationError(f"Unable to read secret file: {source}") from exc
        workdir.mkdir(parents=True, exist_ok=True)
        workdir.chmod(0o700)
        write_text_atomically(workdir / "mtproxy-secret", f"{secret}\n", 0o600)

    @staticmethod
    def _require_script(path: Path) -> None:
        if not path.is_file():
            raise ConfigurationError(f"Required compatibility script is missing: {path}")


def _request_from_state(state: DeploymentState) -> DeploymentRequest:
    return DeploymentRequest(
        port_range=state.port_range,
        workdir=state.workdir,
        public_ip=state.public_ip,
        load_balancer_port=state.load_balancer_port,
        name_prefix=state.name_prefix,
        proxy_image=state.proxy_image,
        build_local_proxy_image=state.build_local_proxy_image,
        mtproxy_commit=state.mtproxy_commit,
        load_balancer_name=state.load_balancer_name,
        load_balancer_image=state.load_balancer_image,
        build_local_load_balancer_image=state.build_local_load_balancer_image,
        pull_policy=state.pull_policy,
        pull_retries=state.pull_retries,
        pull_retry_delay=state.pull_retry_delay,
        use_dd_secret=state.use_dd_secret,
        enable_load_balancer=state.enable_load_balancer,
        mtproxy_platform=state.mtproxy_platform,
    )


def _yes_no(value: bool) -> str:
    return "yes" if value else "no"


def _natural_name_key(value: str) -> tuple[str, int]:
    match = re.fullmatch(r"(.*?)([0-9]+)", value)
    if match is None:
        return value, 0
    return match.group(1), int(match.group(2))
