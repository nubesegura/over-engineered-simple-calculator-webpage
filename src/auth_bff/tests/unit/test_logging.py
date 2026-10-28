import logging

from auth_bff.config.logging import configure_logging


def test_botocore_is_kept_at_warning_so_request_parameters_are_never_logged() -> None:
    logging.getLogger("botocore").setLevel(logging.DEBUG)

    configure_logging()

    assert logging.getLogger("botocore").level == logging.WARNING
    assert logging.getLogger("boto3").level == logging.WARNING
