from __future__ import annotations

from pathlib import Path

from mtproxyctl.deployment.models import ProjectPaths
from mtproxyctl.infrastructure.commands import CommandResult, CommandSpec
from mtproxyctl.monitoring.models import MonitoringTarget
from mtproxyctl.monitoring.service import MonitoringService, parse_mtproxy_stats
from tests_python.helpers import RecordingRunner


def test_parse_mtproxy_stats_keeps_only_allowlisted_numeric_metrics() -> None:
    metrics = parse_mtproxy_stats(
        "HTTP/1.0 200 OK\r\n\r\n"
        "workers\t2\n"
        "total_ready_targets\t10\n"
        "total_ready_targets\t11\n"
        "not_allowed\t99\n"
        "mtproto_proxy_errors\tnot-a-number\n"
    )

    assert metrics == {"workers": "2", "total_ready_targets": "10"}


def test_collect_writes_success_and_failure_metrics_atomically(tmp_path: Path) -> None:
    list_command = ("docker", "ps", "--format", "{{.Names}}")
    exec_prefix = ("docker", "exec")
    runner = RecordingRunner(
        results={
            list_command: CommandResult(
                argv=list_command,
                returncode=0,
                stdout="proxy-2\nunrelated\nproxy-1\n",
                stderr="",
            )
        }
    )
    service = MonitoringService(runner=runner, project_paths=ProjectPaths(tmp_path))
    output = tmp_path / "metrics" / "mtproxy.prom"

    def run_with_stats(command: CommandSpec) -> CommandResult:
        if command.argv[:2] != exec_prefix:
            return runner.results[command.argv]
        if command.argv[2] == "proxy-1":
            return CommandResult(
                argv=command.argv,
                returncode=0,
                stdout="workers\t2\ntotal_ready_targets\t10\n",
                stderr="",
            )
        return CommandResult(
            argv=command.argv,
            returncode=1,
            stdout="",
            stderr="unavailable",
        )

    runner.responder = run_with_stats

    service.collect(
        MonitoringTarget(
            name_prefix="proxy",
            expected_count=2,
            output_file=output,
        )
    )

    rendered = output.read_text()
    assert "mtproxy_expected_containers 2" in rendered
    assert "mtproxy_running_containers 2" in rendered
    assert 'mtproxy_scrape_success{container="proxy-1"} 1' in rendered
    assert 'mtproxy_total_ready_targets{container="proxy-1"} 10' in rendered
    assert 'mtproxy_scrape_success{container="proxy-2"} 0' in rendered
    assert output.stat().st_mode & 0o777 == 0o644
