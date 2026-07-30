#!/usr/bin/env python3
"""Seed a dev Tackle Hub with an Application and a source Identity.

The harness calls FetchApp(appID) and FetchGitCreds(appID) at startup and will
not run without both. This creates the minimum Hub state that satisfies them.

Idempotent: re-running reuses existing records by name rather than duplicating.

Shapes come from tackle2-hub shared/api:
  Identity     core.go        {kind, name, user, password, key, settings}
  Repository   core.go        {kind, url, branch, tag, path}
  IdentityRef  application.go {id, role}   -- role is required
  Application  application.go {name, repository, identities}

Prints progress to stderr and the application ID as the final stdout line.
"""

import json
import os
import sys
import urllib.error
import urllib.request

HUB = os.environ["HUB_URL"].rstrip("/")


def log(msg):
    print(f"    {msg}", file=sys.stderr)


def call(method, path, body=None):
    url = f"{HUB}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Accept", "application/json")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:400]
        raise SystemExit(f"ERROR: {method} {path} -> {e.code}\n{detail}") from e
    except urllib.error.URLError as e:
        raise SystemExit(f"ERROR: cannot reach Hub at {url}: {e.reason}") from e


def find_by_name(path, name):
    for item in call("GET", path) or []:
        if item.get("name") == name:
            return item
    return None


def main():
    identity_name = os.environ["IDENTITY_NAME"]
    app_name = os.environ["APP_NAME"]

    identity = find_by_name("/identities", identity_name)
    if identity:
        log(f"identity '{identity_name}' already exists (id={identity['id']})")
    else:
        identity = call(
            "POST",
            "/identities",
            {
                # kind 'source' is what the harness looks up for git read creds.
                "kind": "source",
                "name": identity_name,
                "description": "Dev git credential seeded by hack/dev/hub.sh",
                "user": os.environ["GIT_USER"],
                "password": os.environ["GIT_TOKEN"],
            },
        )
        log(f"created identity '{identity_name}' (id={identity['id']})")

    repo = {
        "kind": "git",
        "url": os.environ["REPO_URL"],
        "branch": os.environ["REPO_BRANCH"],
    }

    app = find_by_name("/applications", app_name)
    if app:
        current = app.get("repository") or {}
        if (current.get("url"), current.get("branch")) != (repo["url"], repo["branch"]):
            # Update in place rather than skipping: pointing the dev app at a
            # different repository is the main reason to re-run this.
            log(f"application '{app_name}' repo differs; updating")
            app["repository"] = repo
            app["identities"] = [{"id": identity["id"], "role": "source"}]
            call("PUT", f"/applications/{app['id']}", app)
            app = call("GET", f"/applications/{app['id']}")
        else:
            log(f"application '{app_name}' already exists (id={app['id']})")
    else:
        app = call(
            "POST",
            "/applications",
            {
                "name": app_name,
                "description": "Dev application seeded by hack/dev/hub.sh",
                "repository": repo,
                # role is required on IdentityRef.
                "identities": [{"id": identity["id"], "role": "source"}],
            },
        )
        log(f"created application '{app_name}' (id={app['id']})")

    log(f"repository: {os.environ['REPO_URL']} @ {os.environ['REPO_BRANCH']}")
    # Final stdout line: the app id, consumed by hub.sh.
    print(app["id"])


if __name__ == "__main__":
    main()
