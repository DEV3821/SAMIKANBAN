import json
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.request import urlopen

from playwright.sync_api import sync_playwright


REPO_ROOT = Path(__file__).resolve().parents[1]
CHROME = Path(r"C:\Program Files\Google\Chrome\Application\chrome.exe")


def resource(hash_value, last_write="2026-08-03T08:00:00Z", length=10):
    return {
        "exists": True,
        "lastWriteUtc": last_write,
        "length": length,
        "hash": hash_value,
    }


def healthy_status(include_optional=True):
    status = {
        "ok": True,
        "mode": "team-canonical",
        "teamReachable": True,
        "source": {
            "projects": resource("projects-hash"),
            "audit": resource("audit-hash", length=0),
        },
        "local": {
            "projects": resource("projects-hash"),
            "audit": resource("audit-hash", length=0),
        },
    }
    if include_optional:
        status["boardOrderJson"] = {"exists": False, "lastWriteUtc": "", "length": 0, "hash": ""}
        status["local"]["boardOrder"] = {"exists": False, "lastWriteUtc": "", "length": 0, "hash": ""}
        status["projectFileIndexJson"] = {
            "exists": True,
            "lastWriteUtc": "2026-08-03T08:00:00Z",
            "length": 12,
            "signature": "2026-08-03T08:00:00Z|12",
            "indexRevision": 2,
        }
        status["local"]["projectFileIndex"] = resource(
            "runtime-index-sha256",
            last_write="2026-08-03T08:00:00Z",
            length=12,
        )
    return status


def lightweight_state():
    return {
        "ok": True,
        "canonicalAvailable": True,
        "mode": "team-canonical",
        "projectsRevision": "2026-08-03T08:00:00Z",
        "projectsSignature": "2026-08-03T08:00:00Z|10",
        "boardOrderRevision": 2,
        "boardOrderChangeId": "synthetic-order-2",
        "boardOrderSignature": "2026-08-03T08:00:00Z|12",
        "latestAuditSignature": "2026-08-03T08:00:00Z|0",
        "projectFileIndexRevision": 2,
        "projectFileIndexSignature": "2026-08-03T08:00:00Z|12",
    }


def parse_fixture_output(text):
    values = {}
    for line in text.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


def stop_process(pid):
    if pid:
        subprocess.run(
            ["taskkill", "/PID", str(pid), "/T", "/F"],
            check=False,
            capture_output=True,
            text=True,
        )


def main():
    if not CHROME.is_file():
        raise RuntimeError(f"Chrome executable not found: {CHROME}")

    fixture_root = Path(tempfile.mkdtemp(prefix="sami-sync-indicator-test-"))
    server_pids = []
    assertions = 0

    def check(condition, message):
        nonlocal assertions
        assertions += 1
        if not condition:
            raise AssertionError(message)

    try:
        fixture_script = REPO_ROOT / "tools" / "start_browser_fixture.ps1"
        completed = subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(fixture_script),
                "-TempRoot",
                str(fixture_root),
                "-NoBrowser",
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=120,
        )
        values = parse_fixture_output(completed.stdout)
        server_pids = [
            values.get("BROWSER_FIXTURE_CLIENT_A_SERVER_PID"),
            values.get("BROWSER_FIXTURE_CLIENT_B_SERVER_PID"),
        ]
        url = values["BROWSER_FIXTURE_CLIENT_A_URL"]
        canonical_index = fixture_root / "canonical" / "data" / "project_file_index.json"
        canonical_index.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "indexRevision": 2,
                    "fileBaselineCompletedAt": "2026-08-03T08:00:00Z",
                    "projects": [],
                }
            ),
            encoding="utf-8",
        )

        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=True, executable_path=str(CHROME))
            page = browser.new_page()
            page.goto(url + "&samiClientLabel=SyncTests", wait_until="domcontentloaded", timeout=20000)
            page.wait_for_function(
                "window.__samiTestHooks && document.getElementById('syncIndicator').classList.contains('synced')",
                timeout=20000,
            )

            actual_status = page.evaluate("""async () => {
                const response = await fetch('api/sync-status', {cache: 'no-store'});
                return response.json();
            }""")
            actual_state = page.evaluate("""async () => {
                const response = await fetch('api/sync-state?test=1', {cache: 'no-store'});
                return response.json();
            }""")
            actual_status_normalised = page.evaluate("payload => normaliseSyncState(payload)", actual_status)
            actual_state_normalised = page.evaluate("payload => normaliseSyncState(payload)", actual_state)
            indicator = page.evaluate("window.__samiTestHooks.getSyncIndicatorState()")
            check(actual_status_normalised["syncHealthy"] is True, "healthy /api/sync-status was not normalised as synced")
            check(actual_state_normalised["responseKind"] == "sync-state", "healthy /api/sync-state was not recognised")
            check(actual_state_normalised["responseValid"] is True, "healthy /api/sync-state was treated as malformed")
            check(indicator["label"] == "Team ESMI synced", "healthy UI did not show the synced state")
            check("Sync check failed" not in indicator["label"], "healthy UI showed the stale generic failure")

            cases = []
            cases.append(("hash equality", healthy_status(), lambda n: n["syncHealthy"] is True))
            revision_equal = healthy_status()
            revision_equal["local"]["projectFileIndex"]["hash"] = "different-sha256"
            cases.append(("signature equality without hash equality", revision_equal, lambda n: n["syncHealthy"] is True))
            hash_mismatch = healthy_status()
            hash_mismatch["local"]["projects"]["hash"] = "different-projects-hash"
            cases.append(("project hash mismatch", hash_mismatch, lambda n: n["healthState"] == "revision-mismatch"))
            pfi_mismatch = healthy_status()
            pfi_mismatch["local"]["projectFileIndex"]["lastWriteUtc"] = "2026-08-03T08:00:01Z"
            cases.append(("project index revision mismatch", pfi_mismatch, lambda n: n["healthState"] == "revision-mismatch"))
            pfi_hash_equal = healthy_status()
            pfi_hash_equal["projectFileIndexJson"]["hash"] = "runtime-index-sha256"
            cases.append(("project index hash equality", pfi_hash_equal, lambda n: n["syncHealthy"] is True))
            pfi_hash_mismatch = healthy_status()
            pfi_hash_mismatch["projectFileIndexJson"]["hash"] = "canonical-index-sha256"
            cases.append(("project index hash mismatch", pfi_hash_mismatch, lambda n: n["healthState"] == "revision-mismatch"))
            unavailable = {"ok": True, "mode": "offline", "teamReachable": False}
            cases.append(("canonical unavailable", unavailable, lambda n: n["healthState"] == "unavailable"))
            malformed = {"ok": True, "mode": "team-canonical", "teamReachable": True, "source": {}, "local": {}}
            cases.append(("malformed required response", malformed, lambda n: n["healthState"] == "malformed"))
            legacy = healthy_status(include_optional=False)
            cases.append(("optional fields absent", legacy, lambda n: n["syncHealthy"] is True))

            for name, payload, predicate in cases:
                normalised = page.evaluate("payload => normaliseSyncState(payload)", payload)
                check(predicate(normalised), f"sync normalisation case failed: {name}: {normalised}")

            changed = page.evaluate(
                "pair => syncStateChanged(pair[0], pair[1])",
                [lightweight_state(), {**lightweight_state(), "projectsSignature": "changed|10"}],
            )
            check(changed["changed"] is True and changed["projectsChanged"] is True, "project revision change was not detected")
            order_changed = page.evaluate(
                "pair => syncStateChanged(pair[0], pair[1])",
                [lightweight_state(), {**lightweight_state(), "boardOrderRevision": 3, "boardOrderSignature": "changed|12"}],
            )
            check(order_changed["changed"] is True and order_changed["orderChanged"] is True, "board-order revision change was not detected")
            unchanged = page.evaluate("state => syncStateChanged(state, state)", lightweight_state())
            check(unchanged["changed"] is False, "unchanged polling was treated as a remote change/chime")

            recovered = page.evaluate(
                "payload => { recordSyncCheck(payload, null); return window.__samiTestHooks.getSyncIndicatorState(); }",
                hash_mismatch,
            )
            check(recovered["label"] == "Sync revision differs", "revision drift did not get its distinct warning")
            recovered = page.evaluate(
                "payload => { recordSyncCheck(payload, null); return window.__samiTestHooks.getSyncIndicatorState(); }",
                healthy_status(),
            )
            check(recovered["label"] == "Team ESMI synced", "recovery did not clear the old sync warning")
            repeated = page.evaluate(
                "payload => { recordSyncCheck(payload, null); const first = window.__samiTestHooks.getSyncIndicatorState(); recordSyncCheck(payload, null); const second = window.__samiTestHooks.getSyncIndicatorState(); return {first, second}; }",
                healthy_status(),
            )
            check(repeated["first"]["label"] == repeated["second"]["label"] == "Team ESMI synced", "repeated healthy polling flashed or changed state")

            page.route("**/api/sync-state*", lambda route: route.fulfill(status=503, content_type="application/json", body=json.dumps({"ok": False, "error": "synthetic sync failure"})))
            failure = page.evaluate("""async () => {
                try {
                    await fetchSyncState();
                    return {raised: false, message: ''};
                } catch (error) {
                    return {raised: true, message: error.message};
                }
            }""")
            check(failure["raised"] is True and "synthetic sync failure" in failure["message"], "HTTP sync failure was not surfaced truthfully")
            page.unroute("**/api/sync-state*")
            recovered_after_error = page.evaluate(
                "state => { recordSyncCheck(null, new Error('synthetic sync failure')); clearTransientSyncErrorAfterHealthyState(state); renderSyncIndicator(); return window.__samiTestHooks.getSyncIndicatorState(); }",
                lightweight_state(),
            )
            check(recovered_after_error["label"] == "Team ESMI synced", "healthy polling left a stale sync failure visible")

            browser.close()

        print(json.dumps({"status": "GREEN", "assertions": assertions, "fixture": str(fixture_root)}, ensure_ascii=False))
        print("SYNC_INDICATOR_TESTS_OK")
    finally:
        for pid in server_pids:
            stop_process(pid)
        shutil.rmtree(fixture_root, ignore_errors=True)


if __name__ == "__main__":
    main()
