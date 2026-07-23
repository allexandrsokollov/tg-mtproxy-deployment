"""Application-level errors with stable user-facing meanings."""


class MtproxyctlError(Exception):
    """Base class for expected operational failures."""


class ConfigurationError(MtproxyctlError):
    """Configuration or persisted state is invalid."""


class CommandExecutionError(MtproxyctlError):
    """An external command failed."""


class BackupError(MtproxyctlError):
    """A backup could not be created, verified, or restored safely."""


class MonitoringError(MtproxyctlError):
    """Monitoring could not be configured or verified."""
