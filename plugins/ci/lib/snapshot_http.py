"""
HTTP snapshot layer for eval record/replay.

When EVAL_SNAPSHOT_DIR is set, intercepts urllib calls to record or replay
HTTP responses. When unset, passes through to real urllib with zero overhead.

Env vars:
  EVAL_SNAPSHOT_DIR     — directory for snapshot storage (enables snapshot mode)
  EVAL_SNAPSHOT_RECORD  — set to "1" to record; omit to replay
"""

import hashlib
import io
import json
import os
import urllib.request
import urllib.error
from datetime import datetime, timezone

SNAPSHOT_DIR_ENV = "EVAL_SNAPSHOT_DIR"
RECORD_ENV = "EVAL_SNAPSHOT_RECORD"

REDACTED_HEADERS = frozenset({"authorization", "cookie", "set-cookie"})


def _snapshot_dir():
    return os.environ.get(SNAPSHOT_DIR_ENV)


def _is_record_mode():
    return os.environ.get(RECORD_ENV, "") == "1"


def _url_hash(url):
    return hashlib.sha256(url.encode()).hexdigest()[:12]


def _extract_url(url_or_request):
    if isinstance(url_or_request, urllib.request.Request):
        return url_or_request.full_url
    return str(url_or_request)


def _responses_dir(snapshot_dir):
    return os.path.join(snapshot_dir, "http_responses")


def _save_response(snapshot_dir, url, body, status_code, headers):
    resp_dir = _responses_dir(snapshot_dir)
    os.makedirs(resp_dir, exist_ok=True)

    url_h = _url_hash(url)
    filepath = os.path.join(resp_dir, f"{url_h}.json")

    safe_headers = {k: v for k, v in headers.items()
                    if k.lower() not in REDACTED_HEADERS}

    record = {
        "url": url,
        "status_code": status_code,
        "headers": safe_headers,
        "body": body,
    }
    with open(filepath, "w") as f:
        json.dump(record, f, indent=2)

    index_path = os.path.join(resp_dir, "index.json")
    index = {}
    if os.path.exists(index_path):
        with open(index_path) as f:
            index = json.load(f)

    index[url_h] = {
        "url": url,
        "status_code": status_code,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
    with open(index_path, "w") as f:
        json.dump(index, f, indent=2, sort_keys=True)


def _load_response(snapshot_dir, url):
    resp_dir = _responses_dir(snapshot_dir)
    url_h = _url_hash(url)
    filepath = os.path.join(resp_dir, f"{url_h}.json")

    if not os.path.exists(filepath):
        raise FileNotFoundError(
            f"No snapshot for URL: {url}\n"
            f"Expected file: {filepath}\n"
            f"Run with EVAL_SNAPSHOT_RECORD=1 to record this response."
        )

    with open(filepath) as f:
        record = json.load(f)

    return SnapshotResponse(
        body=record["body"].encode("utf-8"),
        status=record.get("status_code", 200),
        url=record.get("url", url),
    )


class SnapshotResponse:
    """Minimal file-like response object compatible with urllib's HTTPResponse."""

    def __init__(self, body, status=200, url=""):
        self.status = status
        self.code = status
        self._body = body
        self.url = url

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass


def snapshot_urlopen(url_or_request, *, timeout=30, data=None):
    """
    Drop-in replacement for urllib.request.urlopen().

    Passthrough when EVAL_SNAPSHOT_DIR is unset.
    Records responses when EVAL_SNAPSHOT_RECORD=1.
    Replays from disk otherwise.
    """
    snap_dir = _snapshot_dir()
    if snap_dir is None:
        return urllib.request.urlopen(url_or_request, timeout=timeout, data=data)

    url = _extract_url(url_or_request)

    if _is_record_mode():
        response = urllib.request.urlopen(url_or_request, timeout=timeout, data=data)
        body = response.read()
        headers = dict(response.headers) if hasattr(response, "headers") else {}
        status = response.status if hasattr(response, "status") else 200

        _save_response(snap_dir, url, body.decode("utf-8", errors="replace"),
                       status, headers)

        return SnapshotResponse(body=body, status=status, url=url)

    return _load_response(snap_dir, url)
