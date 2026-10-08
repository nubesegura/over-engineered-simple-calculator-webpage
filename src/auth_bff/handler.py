"""AWS Lambda entrypoint (function URL). Thin: configuration is validated at cold start."""

import os
from typing import Any

from auth_bff.config.container import build_container

_container = build_container(os.environ)


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    return _container.function_url.handle(event, context.aws_request_id)
