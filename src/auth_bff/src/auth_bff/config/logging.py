"""Structured logging with the standard library: one JSON line per request."""

import json
import logging

from auth_bff.application.ports import RequestRecord

REQUEST_LOGGER_NAME = "auth_bff.request"
_AWS_LOGGERS = ("boto3", "botocore")


def configure_logging() -> None:
    """Log at INFO. Lambda already installs a root handler; locally add a plain one.

    The AWS libraries are held at WARNING: at DEBUG they log request parameters, which here
    include the password, the client secret and the secret hash.
    """
    logging.getLogger(REQUEST_LOGGER_NAME).setLevel(logging.INFO)
    for name in _AWS_LOGGERS:
        logging.getLogger(name).setLevel(logging.WARNING)
    if not logging.getLogger().handlers:
        logging.basicConfig(format="%(message)s")


class JsonRequestLog:
    """Writes a ``RequestRecord`` as one JSON line. Absent optional fields are omitted."""

    def __init__(self, logger: logging.Logger | None = None) -> None:
        self._logger = logger or logging.getLogger(REQUEST_LOGGER_NAME)

    def record(self, record: RequestRecord) -> None:
        fields = {
            "endpoint": record.endpoint,
            "status": record.status,
            "outcome": record.outcome,
            "request_id": record.request_id,
            "error_type": record.error_type,
            "username_hash": record.username_hash,
        }
        line = {name: value for name, value in fields.items() if value is not None}
        self._logger.info(json.dumps(line, separators=(",", ":")))
