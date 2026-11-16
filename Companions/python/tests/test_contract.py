"""Contract conformance: examples and real responses must validate against contract/*.schema.json."""

import json
import re
import shutil
import subprocess
import urllib.request
from pathlib import Path

import pytest

jsonschema = pytest.importorskip("jsonschema")

from test_router import BASE, Harness  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
CONTRACT = ROOT / "contract"
SCHEMA_FOR = {
    "status": "status",
    "status-mixed-revisions": "status",
    "manifest": "manifest",
    "metrics": "metrics",
    "leads": "events",
    "leads-masked-label": "events",
    "events": "events",
    "error": "error",
}


def schema(name):
    s = json.loads((CONTRACT / f"{name}.schema.json").read_text())
    jsonschema.Draft202012Validator.check_schema(s)
    return s


def validate(body, name):
    jsonschema.Draft202012Validator(schema(name), format_checker=jsonschema.FormatChecker()).validate(body)


def test_every_example_file_is_covered():
    names = sorted(p.name[: -len(".example.json")] for p in (CONTRACT / "examples").glob("*.example.json"))
    assert names == sorted(SCHEMA_FOR)


@pytest.mark.parametrize("example", sorted(SCHEMA_FOR))
def test_examples_validate_and_are_marked_as_examples(example):
    body = json.loads((CONTRACT / "examples" / f"{example}.example.json").read_text())
    assert "not live data" in body["_example_notice"]
    validate(body, SCHEMA_FOR[example])


def test_canonical_status_example_has_exactly_the_documented_keys():
    body = json.loads((CONTRACT / "examples" / "status.example.json").read_text())
    body.pop("_example_notice")
    assert list(body) == ["schema_version", "product_id", "component_id", "environment", "observed_at", "release", "health", "metrics", "capabilities"]
    assert body["metrics"] == {"leads_24h": 12, "signups_24h": 9}


@pytest.mark.parametrize("route,name", [("status", "status"), ("manifest", "manifest"), ("metrics?window=30d", "metrics"), ("leads?limit=5", "events"), ("events", "events")])
def test_python_router_responses_validate(route, name):
    r = Harness(leads_masked_label=True).get(f"{BASE}/{route}")
    assert r.status_code == 200
    validate(r.json(), name)


@pytest.mark.parametrize("path,token", [("status", None), ("metrics?window=1h", "ok"), ("nope", "ok")])
def test_python_router_errors_validate(path, token):
    h = Harness()
    r = h.get(f"{BASE}/{path}") if token else h.get(f"{BASE}/{path}", token=None)
    assert r.status_code >= 400
    validate(r.json(), "error")


def test_schema_rejects_contact_fields_on_items():
    body = json.loads((CONTRACT / "examples" / "leads.example.json").read_text())
    body["items"][0]["email"] = "john@example.com"
    with pytest.raises(jsonschema.ValidationError):
        validate(body, "events")
    body["items"][0].pop("email")
    body["items"][0]["label"] = "john@example.com"
    with pytest.raises(jsonschema.ValidationError):
        validate(body, "events")


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_node_example_server_responses_validate():
    token = "contract-check-token-0123456789"
    proc = subprocess.Popen(
        ["node", str(ROOT / "node" / "example-server.js"), "--port", "0", "--token", token, "--masked-labels", "--quiet"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        base = None
        for _ in range(20):
            line = proc.stdout.readline()
            m = re.search(r"base URL:\s+(http://127\.0\.0\.1:\d+/_forgedeck/v1)", line)
            if m:
                base = m.group(1)
                break
        assert base, "example server did not start"
        for route, name in [("status", "status"), ("manifest", "manifest"), ("metrics?window=7d", "metrics"), ("leads?limit=5", "events"), ("events?limit=100", "events")]:
            req = urllib.request.Request(f"{base}/{route}", headers={"Authorization": f"Bearer {token}"})
            with urllib.request.urlopen(req, timeout=5) as resp:  # noqa: S310 - loopback only
                validate(json.loads(resp.read()), name)
    finally:
        proc.terminate()
        proc.wait(timeout=5)
