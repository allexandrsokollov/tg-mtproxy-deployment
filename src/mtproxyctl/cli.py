from __future__ import annotations

import argparse
from pathlib import Path
import sys

from mtproxyctl.backup.service import BackupService
from mtproxyctl.config.models import DeploymentRequest, PortRange, PullPolicy
from mtproxyctl.deployment.models import ProjectPaths
from mtproxyctl.deployment.service import DeploymentService
from mtproxyctl.errors import BackupError, MonitoringError, MtproxyctlError
from mtproxyctl.infrastructure.commands import SubprocessCommandRunner
from mtproxyctl.minikube.models import MinikubeSetupRequest, PortForwardRequest
from mtproxyctl.minikube.service import MinikubeService
from mtproxyctl.monitoring.models import MonitoringInstallRequest, MonitoringTarget
from mtproxyctl.monitoring.service import MonitoringService
from mtproxyctl.settings import (
    AppSettings,
    BackupSettings,
    DeploymentSettings,
    MinikubeSettings,
    MonitoringSettings,
    load_app_settings,
)


def main(argv: list[str] | None = None) -> int:
    raw_arguments = sys.argv[1:] if argv is None else argv

    try:
        settings = load_app_settings(_env_file_from_arguments(raw_arguments))
        parser = _build_parser(settings)
        args = parser.parse_args(raw_arguments)
        runner = SubprocessCommandRunner(dry_run=args.dry_run)
        project_paths = ProjectPaths(root=args.project_dir.expanduser().resolve())
        deployment_service = DeploymentService(runner=runner, project_paths=project_paths)

        if args.command == "doctor":
            return _run_doctor(deployment_service)
        if args.command == "deploy":
            return _run_deploy(args, deployment_service)
        if args.command == "backup":
            return _run_backup(args, BackupService(), deployment_service)
        if args.command == "monitoring":
            monitoring_service = MonitoringService(
                runner=runner,
                project_paths=project_paths,
            )
            return _run_monitoring(args, monitoring_service)
        if args.command == "dev":
            minikube_service = MinikubeService(
                runner=runner,
                project_paths=project_paths,
            )
            return _run_dev(args, minikube_service)
    except MtproxyctlError as exc:
        print(f"[!] {exc}", file=sys.stderr)
        return 2

    raise AssertionError(f"Unsupported command: {args.command}")


def _build_parser(settings: AppSettings) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="mtproxyctl",
        description="Manage Telegram MTProxy deployment, backups, and monitoring.",
    )
    parser.add_argument(
        "--env-file",
        type=Path,
        default=Path(".env"),
        help="Dotenv file loaded before environment variables and CLI overrides.",
    )
    parser.add_argument(
        "--project-dir",
        type=Path,
        default=_default_project_dir(settings.project_dir),
        help="Checkout containing the compatibility Bash scripts.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Validate and show operations without running mutating commands.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("doctor", help="Check local prerequisites.")
    _add_deploy_parser(subparsers, settings.deployment)
    _add_backup_parser(subparsers, settings.deployment, settings.backup)
    _add_monitoring_parser(subparsers, settings.monitoring)
    _add_dev_parser(subparsers, settings.minikube)
    return parser


def _add_deploy_parser(
    subparsers: argparse._SubParsersAction[argparse.ArgumentParser],
    settings: DeploymentSettings,
) -> None:
    deploy = subparsers.add_parser("deploy", help="Plan and manage the proxy deployment.")
    commands = deploy.add_subparsers(dest="deploy_command", required=True)
    plan = commands.add_parser("plan", help="Validate and show the deployment operations.")
    apply = commands.add_parser("apply", help="Apply a deployment through the proven backend.")
    for command_parser in (plan, apply):
        _add_deployment_request_arguments(command_parser, settings)
    apply.add_argument(
        "--secret-file",
        type=Path,
        default=settings.secret_file,
        help="Protected file containing a custom 32-hex-character client secret.",
    )
    state_path = settings.workdir / "deployment.env"
    status = commands.add_parser("status", help="Compare expected and actual containers.")
    status.add_argument(
        "--state",
        type=Path,
        default=state_path,
    )
    redeploy = commands.add_parser("redeploy", help="Redeploy from persisted state.")
    redeploy.add_argument(
        "--state",
        type=Path,
        default=state_path,
    )


def _add_deployment_request_arguments(
    parser: argparse.ArgumentParser,
    settings: DeploymentSettings,
) -> None:
    default_port_range = (
        PortRange.parse(settings.port_range) if settings.port_range is not None else None
    )
    parser.add_argument(
        "--port-range",
        required=default_port_range is None,
        type=PortRange.parse,
        default=default_port_range,
    )
    parser.add_argument("--workdir", type=Path, default=settings.workdir)
    parser.add_argument("--public-ip", default=settings.public_ip)
    parser.add_argument("--lb-port", type=int, default=settings.load_balancer_port)
    parser.add_argument("--prefix", default=settings.name_prefix)
    parser.add_argument("--image", default=settings.proxy_image)
    parser.add_argument(
        "--build-local-image",
        action=argparse.BooleanOptionalAction,
        default=settings.build_local_proxy_image,
    )
    parser.add_argument(
        "--mtproxy-commit",
        default=settings.mtproxy_commit,
    )
    parser.add_argument("--platform", default=settings.mtproxy_platform)
    parser.add_argument("--lb-name", default=settings.load_balancer_name)
    parser.add_argument("--lb-image", default=settings.load_balancer_image)
    parser.add_argument(
        "--build-local-lb",
        action=argparse.BooleanOptionalAction,
        default=settings.build_local_load_balancer_image,
    )
    parser.add_argument(
        "--pull-policy",
        type=PullPolicy,
        choices=tuple(PullPolicy),
        default=settings.pull_policy,
    )
    parser.add_argument("--pull-retries", type=int, default=settings.pull_retries)
    parser.add_argument("--pull-retry-delay", type=int, default=settings.pull_retry_delay)
    parser.add_argument(
        "--dd-secret",
        action=argparse.BooleanOptionalAction,
        default=settings.use_dd_secret,
    )
    parser.add_argument(
        "--enable-lb",
        action=argparse.BooleanOptionalAction,
        default=settings.enable_load_balancer,
    )


def _add_backup_parser(
    subparsers: argparse._SubParsersAction[argparse.ArgumentParser],
    deployment_settings: DeploymentSettings,
    backup_settings: BackupSettings,
) -> None:
    workdir = deployment_settings.workdir
    backup_dir = backup_settings.backup_dir or Path(f"{workdir}-backups")
    backup = subparsers.add_parser("backup", help="Create, verify, restore, and prune backups.")
    commands = backup.add_subparsers(dest="backup_command", required=True)
    create = commands.add_parser("create", help="Create a checksummed protected archive.")
    create.add_argument("--workdir", type=Path, default=workdir)
    create.add_argument("--backup-dir", type=Path, default=backup_settings.backup_dir)
    listing = commands.add_parser("list", help="List local backup archives.")
    listing.add_argument("--backup-dir", type=Path, default=backup_dir)
    verify = commands.add_parser("verify", help="Verify archive paths, contents, and checksums.")
    verify.add_argument("archive", type=Path)
    restore = commands.add_parser("restore", help="Restore an archive safely.")
    restore.add_argument("archive", type=Path)
    restore.add_argument("--workdir", type=Path, default=workdir)
    restore.add_argument("--force", action="store_true")
    restore.add_argument("--redeploy", action="store_true")
    prune = commands.add_parser("prune", help="Remove archives beyond the retention count.")
    prune.add_argument("--backup-dir", type=Path, default=backup_dir)
    prune.add_argument("--keep", type=int, required=True)
    prune.add_argument(
        "--yes",
        action="store_true",
        help="Confirm deletion of archives outside retention.",
    )


def _add_monitoring_parser(
    subparsers: argparse._SubParsersAction[argparse.ArgumentParser],
    settings: MonitoringSettings,
) -> None:
    monitoring = subparsers.add_parser("monitoring", help="Install and inspect monitoring.")
    commands = monitoring.add_subparsers(dest="monitoring_command", required=True)
    for command_name, help_text in (
        ("install", "Install and configure Grafana Alloy and systemd units."),
        ("configure", "Reconfigure Grafana Alloy and systemd units."),
    ):
        install = commands.add_parser(command_name, help=help_text)
        install.add_argument(
            "--metrics-url",
            required=settings.metrics_url is None,
            default=settings.metrics_url,
        )
        install.add_argument(
            "--metrics-user",
            required=settings.metrics_user is None,
            default=settings.metrics_user,
        )
        install.add_argument(
            "--logs-url",
            required=settings.logs_url is None,
            default=settings.logs_url,
        )
        install.add_argument(
            "--logs-user",
            required=settings.logs_user is None,
            default=settings.logs_user,
        )
        install.add_argument(
            "--token-file",
            required=settings.token_file is None,
            type=Path,
            default=settings.token_file,
        )
        install.add_argument(
            "--deployment-state",
            type=Path,
            default=settings.deployment_state,
        )
        install.add_argument("--prefix", default=settings.name_prefix)
        install.add_argument("--expected-count", type=int, default=settings.expected_count)
        install.add_argument("--force", action="store_true")
    collect = commands.add_parser("collect", help="Collect MTProxy stats once.")
    collect.add_argument(
        "--deployment-state",
        type=Path,
        default=settings.deployment_state,
    )
    collect.add_argument("--prefix", default=settings.name_prefix)
    collect.add_argument("--expected-count", type=int, default=settings.expected_count)
    collect.add_argument("--output", type=Path, default=settings.metrics_file)
    status = commands.add_parser("status", help="Check Alloy, collector, and metrics state.")
    status.add_argument("--metrics-file", type=Path, default=settings.metrics_file)
    verify = commands.add_parser("verify", help="Require monitoring to be healthy.")
    verify.add_argument("--metrics-file", type=Path, default=settings.metrics_file)


def _add_dev_parser(
    subparsers: argparse._SubParsersAction[argparse.ArgumentParser],
    settings: MinikubeSettings,
) -> None:
    dev = subparsers.add_parser("dev", help="Manage the optional macOS development cluster.")
    dev_commands = dev.add_subparsers(dest="dev_command", required=True)
    minikube = dev_commands.add_parser("minikube", help="Manage Minikube.")
    commands = minikube.add_subparsers(dest="minikube_command", required=True)
    setup = commands.add_parser("setup", help="Install and start Minikube.")
    setup.add_argument("--profile", default=settings.profile)
    setup.add_argument("--k8s-version", default=settings.kubernetes_version)
    setup.add_argument("--cpus", type=int, default=settings.cpus)
    setup.add_argument("--memory", type=int, default=settings.memory_mb)
    setup.add_argument("--disk-size", default=settings.disk_size)
    setup.add_argument("--pf-namespace", default=settings.port_forward_namespace)
    setup.add_argument("--pf-service", default=settings.port_forward_service)
    setup.add_argument("--pf-local-port", type=int, default=settings.port_forward_local_port)
    setup.add_argument("--pf-remote-port", type=int, default=settings.port_forward_remote_port)
    status = commands.add_parser("status", help="Show Minikube profile status.")
    status.add_argument("--profile", default=settings.profile)


def _run_doctor(service: DeploymentService) -> int:
    checks = service.doctor()
    for check in checks:
        marker = "ok" if check.healthy else "missing"
        print(f"{marker:7} {check.name}: {check.detail}")
    return 0 if all(check.healthy for check in checks) else 1


def _run_deploy(args: argparse.Namespace, service: DeploymentService) -> int:
    if args.deploy_command in {"plan", "apply"}:
        request = _deployment_request(args)
        if args.deploy_command == "plan" or args.dry_run:
            for index, action in enumerate(service.plan(request).actions, start=1):
                print(f"{index}. {action}")
            if args.dry_run and args.deploy_command == "apply":
                print("Dry run: deployment command was not executed.")
            return 0
        service.apply(request, secret_file=args.secret_file)
        return 0
    if args.deploy_command == "redeploy":
        if args.dry_run:
            print(f"Dry run: would redeploy from {args.state}")
            return 0
        service.redeploy(args.state.expanduser())
        return 0
    status = service.status(args.state.expanduser())
    print(
        f"Proxies: {status.running_proxy_count}/{status.expected_proxy_count}; "
        f"load balancer: "
        f"{'running' if status.load_balancer_running else 'missing or stopped'}"
    )
    for container in status.containers:
        print(f"  {container.name}: {container.status}")
    return 0 if status.healthy else 1


def _deployment_request(args: argparse.Namespace) -> DeploymentRequest:
    return DeploymentRequest(
        port_range=args.port_range,
        workdir=args.workdir.expanduser(),
        public_ip=args.public_ip,
        load_balancer_port=args.lb_port,
        name_prefix=args.prefix,
        proxy_image=args.image,
        build_local_proxy_image=args.build_local_image,
        mtproxy_commit=args.mtproxy_commit,
        load_balancer_name=args.lb_name,
        load_balancer_image=args.lb_image,
        build_local_load_balancer_image=args.build_local_lb,
        pull_policy=args.pull_policy,
        pull_retries=args.pull_retries,
        pull_retry_delay=args.pull_retry_delay,
        use_dd_secret=args.dd_secret,
        enable_load_balancer=args.enable_lb,
        mtproxy_platform=args.platform,
    )


def _run_backup(
    args: argparse.Namespace,
    service: BackupService,
    deployment_service: DeploymentService,
) -> int:
    if args.backup_command == "create":
        backup_dir = args.backup_dir or Path(f"{args.workdir}-backups")
        if args.dry_run:
            print(f"Dry run: would back up {args.workdir} to {backup_dir}")
            return 0
        archive = service.create(args.workdir.expanduser(), backup_dir.expanduser())
        print(f"Backup created: {archive}")
        return 0
    if args.backup_command == "list":
        for archive in service.list_archives(args.backup_dir.expanduser()):
            print(archive)
        return 0
    if args.backup_command == "verify":
        verification = service.verify(args.archive.expanduser())
        print(
            f"Backup verified: version {verification.manifest.format_version}, "
            f"{len(verification.manifest.files)} files"
        )
        return 0
    if args.backup_command == "restore":
        workdir = args.workdir.expanduser()
        if args.dry_run:
            service.verify(args.archive.expanduser())
            print(f"Dry run: archive is valid; would restore to {workdir}")
            return 0
        service.restore(
            args.archive.expanduser(),
            workdir,
            force=args.force,
        )
        print(f"Backup restored to {workdir}")
        if args.redeploy:
            deployment_service.redeploy(workdir / "deployment.env")
        return 0
    if not args.yes:
        raise BackupError("Backup pruning requires --yes because it deletes archives")
    if args.dry_run:
        archives = service.list_archives(args.backup_dir.expanduser())
        for archive in archives[args.keep :]:
            print(f"Would remove: {archive}")
        return 0
    removed = service.prune(args.backup_dir.expanduser(), args.keep)
    for archive in removed:
        print(f"Removed: {archive}")
    return 0


def _run_monitoring(args: argparse.Namespace, service: MonitoringService) -> int:
    if args.monitoring_command in {"install", "configure"}:
        service.install(
            MonitoringInstallRequest(
                metrics_url=args.metrics_url,
                metrics_user=args.metrics_user,
                logs_url=args.logs_url,
                logs_user=args.logs_user,
                token_file=args.token_file.expanduser(),
                deployment_state=(
                    args.deployment_state.expanduser()
                    if args.deployment_state is not None
                    else None
                ),
                name_prefix=args.prefix,
                expected_count=args.expected_count,
                force=args.force,
            )
        )
        if args.dry_run:
            print("Dry run: monitoring setup command was not executed.")
        return 0
    if args.monitoring_command == "collect":
        target = _monitoring_target(args, service)
        if args.dry_run:
            print(f"Dry run: would collect {target.name_prefix} metrics into {target.output_file}")
            return 0
        output = service.collect(target)
        print(f"Metrics written: {output}")
        return 0
    status = service.status(args.metrics_file.expanduser())
    print(f"Alloy: {'active' if status.alloy_active else 'inactive'}")
    print(f"Collector timer: {'active' if status.collector_timer_active else 'inactive'}")
    print(
        f"Metrics: {'available' if status.metrics_available else 'missing'} ({status.metrics_file})"
    )
    if args.monitoring_command == "verify" and not status.healthy:
        raise MonitoringError("Monitoring health verification failed")
    return 0 if status.healthy else 1


def _monitoring_target(
    args: argparse.Namespace,
    service: MonitoringService,
) -> MonitoringTarget:
    if args.deployment_state is not None:
        return service.target_from_state(
            args.deployment_state.expanduser(),
            args.output.expanduser(),
        )
    if args.prefix is None or args.expected_count is None:
        raise MonitoringError(
            "Collect requires --deployment-state or both --prefix and --expected-count"
        )
    return MonitoringTarget(
        name_prefix=args.prefix,
        expected_count=args.expected_count,
        output_file=args.output.expanduser(),
    )


def _run_dev(args: argparse.Namespace, service: MinikubeService) -> int:
    if args.minikube_command == "status":
        print(service.status(args.profile), end="")
        return 0
    port_forward_values = (
        args.pf_namespace,
        args.pf_service,
        args.pf_local_port,
        args.pf_remote_port,
    )
    if any(value is not None for value in port_forward_values) and not all(
        value is not None for value in port_forward_values
    ):
        raise MtproxyctlError(
            "Persistent port-forwarding requires namespace, service, local port, and remote port"
        )
    port_forward = (
        PortForwardRequest(
            namespace=args.pf_namespace,
            service=args.pf_service,
            local_port=args.pf_local_port,
            remote_port=args.pf_remote_port,
        )
        if all(value is not None for value in port_forward_values)
        else None
    )
    service.setup(
        MinikubeSetupRequest(
            profile=args.profile,
            kubernetes_version=args.k8s_version,
            cpus=args.cpus,
            memory_mb=args.memory,
            disk_size=args.disk_size,
            port_forward=port_forward,
        )
    )
    if args.dry_run:
        print("Dry run: Minikube setup command was not executed.")
    return 0


def _env_file_from_arguments(arguments: list[str]) -> Path:
    bootstrap_parser = argparse.ArgumentParser(add_help=False)
    bootstrap_parser.add_argument("--env-file", type=Path, default=Path(".env"))
    parsed, _ = bootstrap_parser.parse_known_args(arguments)
    env_file = parsed.env_file
    if not isinstance(env_file, Path):
        raise AssertionError("Parsed env file must be a path")
    return env_file


def _default_project_dir(configured: Path | None) -> Path:
    if configured:
        return configured.expanduser()
    current_directory = Path.cwd()
    if (current_directory / "script.bash").is_file():
        return current_directory
    source_checkout = Path(__file__).resolve().parents[2]
    if (source_checkout / "script.bash").is_file():
        return source_checkout
    return current_directory
