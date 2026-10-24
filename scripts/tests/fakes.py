"""Small in-memory stand-ins for boto3 clients, shared by the script tests (no AWS access)."""

from __future__ import annotations

import io
from typing import Any

from botocore.exceptions import ClientError


def client_error(code: str, message: str = "boom", operation: str = "Op") -> ClientError:
    return ClientError({"Error": {"Code": code, "Message": message}}, operation)


class FakeFactory:
    """Callable (service, region) -> client; remembers which clients were requested."""

    def __init__(self, clients: dict[tuple[str, str], Any] | None = None) -> None:
        self.clients: dict[tuple[str, str], Any] = clients or {}
        self.requested: list[tuple[str, str]] = []

    def __call__(self, service: str, region: str) -> Any:
        self.requested.append((service, region))
        if (service, region) in self.clients:
            return self.clients[(service, region)]
        return self.clients[(service, "*")]


class Clock:
    """Deterministic time: sleeping only moves the clock forward."""

    def __init__(self) -> None:
        self.now = 0.0

    def sleep(self, seconds: float) -> None:
        self.now += seconds

    def monotonic(self) -> float:
        return self.now


def resource(logical: str, kind: str, physical: str, status: str = "CREATE_COMPLETE") -> dict[str, str]:
    return {
        "LogicalResourceId": logical,
        "ResourceType": kind,
        "PhysicalResourceId": physical,
        "ResourceStatus": status,
    }


class FakeCfn:
    """CloudFormation of one Region: stacks, change sets and the calls made, in a shared log."""

    def __init__(self, region: str, log: list[tuple[str, ...]]) -> None:
        self.region = region
        self.log = log
        self.stacks: dict[str, dict[str, Any]] = {}
        self.outputs_on_create: dict[str, dict[str, str]] = {}
        self.scripted_changes: dict[str, list[dict[str, Any]]] = {}
        self.no_changes: set[str] = set()
        self.stuck: set[str] = set()
        self.change_sets: dict[tuple[str, str], dict[str, Any]] = {}
        self.page_size = 2
        self.created: list[dict[str, Any]] = []
        self.policies: dict[str, str] = {}
        self.drift: list[dict[str, Any]] = []
        self.events: list[dict[str, Any]] = []
        self.change_set_state: dict[str, tuple[str, str]] = {}
        self.lag_polls = 0
        self.pending: dict[str, int] = {}
        self.stale_status: dict[str, str] = {}
        self.stale_served = 0
        self.executed: set[str] = set()
        self.failed_execution: set[str] = set()
        self.delete_lag = 0
        self.deleting: dict[str, int] = {}

    def add_stack(self, name: str, status: str, **extra: Any) -> None:
        self.stacks[name] = {"status": status, "outputs": {}, "protection": False, "resources": []}
        self.stacks[name].update(extra)

    def describe_stacks(self, StackName: str) -> dict[str, Any]:
        stack = self.stacks.get(StackName)
        if StackName in self.deleting:
            if self.deleting[StackName] > 0:
                self.deleting[StackName] -= 1
                self.stale_served += 1
            else:
                del self.deleting[StackName]
                stack = self.stacks.pop(StackName, None)
        if stack is None:
            raise client_error("ValidationError", f"Stack with id {StackName} does not exist")
        if self.pending.get(StackName, 0) > 0:
            self.stale_served += 1
            stack = {**stack, "status": self.stale_status[StackName]}
        return {
            "Stacks": [
                {
                    "StackName": StackName,
                    "StackStatus": stack["status"],
                    "EnableTerminationProtection": stack["protection"],
                    "Outputs": [{"OutputKey": k, "OutputValue": v} for k, v in stack["outputs"].items()],
                }
            ]
        }

    def create_change_set(self, **kwargs: Any) -> dict[str, str]:
        name = kwargs["StackName"]
        self.log.append(("create_change_set", name))
        self.created.append(kwargs)
        if name not in self.stacks:
            self.add_stack(name, "REVIEW_IN_PROGRESS")
        changes = self.scripted_changes.get(
            name,
            [
                {
                    "Type": "Resource",
                    "ResourceChange": {
                        "Action": "Add",
                        "LogicalResourceId": f"R{i}",
                        "ResourceType": "AWS::X::Y",
                    },
                }
                for i in range(3)
            ],
        )
        self.change_sets[(name, kwargs["ChangeSetName"])] = {"changes": changes}
        return {"Id": "cs"}

    def describe_change_set(self, StackName: str, ChangeSetName: str, **kwargs: str) -> dict[str, Any]:
        if StackName in self.change_set_state:
            status, reason = self.change_set_state[StackName]
            return {"Status": status, "StatusReason": reason, "Changes": []}
        if StackName in self.no_changes:
            return {
                "Status": "FAILED",
                "StatusReason": "The submitted information didn't contain changes.",
                "Changes": [],
            }
        changes = self.change_sets[(StackName, ChangeSetName)]["changes"]
        start = int(kwargs.get("NextToken", "0"))
        page: dict[str, Any] = {
            "Status": "CREATE_COMPLETE",
            "ExecutionStatus": self.execution_status(StackName),
            "Changes": changes[start : start + self.page_size],
        }
        if start + self.page_size < len(changes):
            page["NextToken"] = str(start + self.page_size)
        return page

    def execution_status(self, stack: str) -> str:
        if stack not in self.executed:
            return "AVAILABLE"
        if stack in self.stuck:
            return "EXECUTE_IN_PROGRESS"
        if self.pending.get(stack, 0) > 0:
            self.pending[stack] -= 1
            return "EXECUTE_IN_PROGRESS"
        return "EXECUTE_FAILED" if stack in self.failed_execution else "EXECUTE_COMPLETE"

    def execute_change_set(self, StackName: str, ChangeSetName: str) -> dict[str, Any]:
        self.log.append(("execute_change_set", StackName))
        stack = self.stacks[StackName]
        created = stack["status"] == "REVIEW_IN_PROGRESS"
        self.executed.add(StackName)
        if StackName in self.stuck:
            stack["status"] = "UPDATE_IN_PROGRESS"
            return {}
        if StackName in self.failed_execution:
            stack["status"] = "ROLLBACK_COMPLETE" if created else "UPDATE_ROLLBACK_COMPLETE"
            return {}
        self.stale_status[StackName] = stack["status"]
        self.pending[StackName] = self.lag_polls
        stack["status"] = "CREATE_COMPLETE" if created else "UPDATE_COMPLETE"
        stack["outputs"] = dict(self.outputs_on_create.get(StackName, stack["outputs"]))
        return {}

    def delete_change_set(self, StackName: str, ChangeSetName: str) -> dict[str, Any]:
        self.log.append(("delete_change_set", StackName))
        self.change_sets.pop((StackName, ChangeSetName), None)
        return {}

    def delete_stack(self, StackName: str) -> dict[str, Any]:
        self.log.append(("delete_stack", StackName))
        if self.delete_lag:
            self.deleting[StackName] = self.delete_lag
        else:
            self.stacks.pop(StackName, None)
        return {}

    def update_termination_protection(self, StackName: str, EnableTerminationProtection: bool) -> dict[str, Any]:
        self.log.append(("termination_protection", StackName, str(EnableTerminationProtection)))
        self.stacks[StackName]["protection"] = EnableTerminationProtection
        return {}

    def set_stack_policy(self, StackName: str, StackPolicyBody: str) -> dict[str, Any]:
        self.log.append(("set_stack_policy", StackName))
        self.policies[StackName] = StackPolicyBody
        return {}

    def get_stack_policy(self, StackName: str) -> dict[str, Any]:
        body = self.policies.get(StackName)
        return {"StackPolicyBody": body} if body else {}

    def list_stack_resources(self, StackName: str) -> dict[str, Any]:
        return {"StackResourceSummaries": self.stacks[StackName]["resources"]}

    def describe_stack_events(self, StackName: str) -> dict[str, Any]:
        return {"StackEvents": self.events}

    def detect_stack_drift(self, StackName: str) -> dict[str, str]:
        self.log.append(("detect_stack_drift", StackName))
        return {"StackDriftDetectionId": "d1"}

    def describe_stack_drift_detection_status(self, StackDriftDetectionId: str) -> dict[str, str]:
        return {
            "DetectionStatus": "DETECTION_COMPLETE",
            "StackDriftStatus": "DRIFTED" if self.drift else "IN_SYNC",
        }

    def describe_stack_resource_drifts(self, StackName: str, **kwargs: Any) -> dict[str, Any]:
        return {"StackResourceDrifts": self.drift}


class FakeBody:
    def __init__(self, data: bytes) -> None:
        self._data = io.BytesIO(data)

    def read(self, size: int = -1) -> bytes:
        return self._data.read(size)
