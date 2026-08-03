"""Full isolated two-client browser acceptance suite for SAMI Project Portfolio.

The runner creates a synthetic canonical root, starts two real local servers, and
keeps all browser profiles, downloads, videos, traces, logs, screenshots, and
telemetry beneath one retained artifact directory.
"""

from __future__ import annotations

import argparse
import importlib.metadata
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from playwright.sync_api import Page, Response, TimeoutError as PlaywrightTimeoutError, sync_playwright


REPO_ROOT = Path(__file__).resolve().parents[1]
CHROME = Path(r"C:\Program Files\Google\Chrome\Application\chrome.exe")
FIXTURE_SCRIPT = REPO_ROOT / "tools" / "start_browser_fixture.ps1"
LANES = ["backlog", "running", "blocked", "done"]
EXPECTED_LANE_LABELS = {"Backlog", "In Progress", "Blocked", "Done"}


def utc_stamp() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2)
        handle.write("\n")


def read_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def parse_fixture_output(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in text.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


def stop_process(pid: str | int | None) -> None:
    if not pid:
        return
    subprocess.run(
        ["taskkill", "/PID", str(pid), "/T", "/F"],
        check=False,
        capture_output=True,
        text=True,
    )


def clone_lanes(value: dict[str, list[str]]) -> dict[str, list[str]]:
    return {lane: [str(item) for item in value.get(lane, [])] for lane in LANES}


def swap_first_two(lanes: dict[str, list[str]], lane: str = "running") -> dict[str, list[str]]:
    next_lanes = clone_lanes(lanes)
    if len(next_lanes.get(lane, [])) < 2:
        raise AssertionError(f"Need two cards in {lane} to exercise order changes: {next_lanes}")
    next_lanes[lane][0], next_lanes[lane][1] = next_lanes[lane][1], next_lanes[lane][0]
    return next_lanes


def wait_until(
    predicate: Callable[[], Any],
    timeout: float = 20.0,
    interval: float = 0.25,
    message: str = "condition was not met",
) -> Any:
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        try:
            result = predicate()
            if result:
                return result
        except Exception as exc:  # the page can be between renders during polling
            last_error = exc
        time.sleep(interval)
    if last_error:
        raise AssertionError(f"{message}: {last_error}") from last_error
    raise AssertionError(message)


class AcceptanceRun:
    def __init__(self, artifact_root: Path) -> None:
        self.artifact_root = artifact_root
        self.fixture_root = artifact_root / "fixture"
        self.assertions = 0
        self.telemetry: list[dict[str, Any]] = []
        self.console_logs: dict[str, list[dict[str, Any]]] = {"Client A": [], "Client B": []}
        self.network_failures: list[dict[str, Any]] = []
        self.response_errors: list[dict[str, Any]] = []
        self.server_pids: list[str] = []
        self.urls: dict[str, str] = {}
        self.runtime_roots: dict[str, Path] = {}
        self.canonical_root: Path | None = None
        self.intentional_failure_urls: set[str] = set()
        self.browser_versions: dict[str, str] = {}
        self.downloads: dict[str, dict[str, Any]] = {}

    def record(self, event: str, **details: Any) -> None:
        self.telemetry.append({"at": utc_stamp(), "event": event, **details})

    def check(self, condition: bool, message: str, **details: Any) -> None:
        self.assertions += 1
        self.record("assertion", name=message, passed=bool(condition), **details)
        if not condition:
            raise AssertionError(message)

    def attach_page_logging(self, page: Page, label: str) -> None:
        def on_console(message: Any) -> None:
            entry = {"type": message.type, "text": message.text, "url": page.url}
            self.console_logs[label].append(entry)

        def on_page_error(error: Exception) -> None:
            self.console_logs[label].append({"type": "pageerror", "text": str(error), "url": page.url})

        def on_request_failed(request: Any) -> None:
            item = {"client": label, "url": request.url, "method": request.method, "failure": request.failure}
            self.network_failures.append(item)

        def on_response(response: Response) -> None:
            if response.status >= 400:
                item = {
                    "client": label,
                    "url": response.url,
                    "status": response.status,
                    "method": response.request.method,
                    "resourceType": response.request.resource_type,
                }
                self.response_errors.append(item)

        page.on("console", on_console)
        page.on("pageerror", on_page_error)
        page.on("requestfailed", on_request_failed)
        page.on("response", on_response)

    def seed_fixture(self) -> None:
        completed = subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(FIXTURE_SCRIPT),
                "-TempRoot",
                str(self.fixture_root),
                "-NoBrowser",
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=120,
        )
        values = parse_fixture_output(completed.stdout)
        self.server_pids = [
            values["BROWSER_FIXTURE_CLIENT_A_SERVER_PID"],
            values["BROWSER_FIXTURE_CLIENT_B_SERVER_PID"],
        ]
        self.urls = {
            "Client A": values["BROWSER_FIXTURE_CLIENT_A_URL"] + "&samiAutoUnlock=1",
            "Client B": values["BROWSER_FIXTURE_CLIENT_B_URL"] + "&samiAutoUnlock=1",
        }
        self.runtime_roots = {
            "Client A": Path(values["BROWSER_FIXTURE_CLIENT_A_RUNTIME"]),
            "Client B": Path(values["BROWSER_FIXTURE_CLIENT_B_RUNTIME"]),
        }
        self.canonical_root = Path(values["BROWSER_FIXTURE_ROOT"]) / "canonical"
        projects_path = self.canonical_root / "data" / "projects.json"
        projects = read_json(projects_path)
        for card in projects["projects"]:
            card_id = str(card["id"])
            card["riskColour"] = "green" if card_id != "browser-beta" else "amber"
            card["folder"] = {"relativePath": f"project_files/{card_id}"}
            card["olderClientField"] = "preserve-this-older-client-field"
            card["legacyField"] = {"source": "older-client", "value": "must-survive-save"}
            card["projectLead"] = card.get("lead", "")
            card["updatedBy"] = "synthetic-fixture"
        write_json(projects_path, projects)
        baseline_time = "2026-08-03T08:00:00Z"
        entries = []
        for card in projects["projects"]:
            entries.append(
                {
                    "cardId": card["id"],
                    "title": card["title"],
                    "folderRelativePath": card["folder"]["relativePath"],
                    "fileCount": 0,
                    "adminCount": 0,
                    "planningCount": 0,
                    "deliveryCount": 0,
                    "meetingsCount": 0,
                    "risksIssuesDecisionsCount": 0,
                    "evidenceCount": 0,
                    "closeoutCount": 0,
                    "needsReviewCount": 0,
                    "files": [],
                }
            )
        write_json(
            self.canonical_root / "data" / "project_file_index.json",
            {
                "schemaVersion": 1,
                "indexRevision": 1,
                "fileBaselineCompletedAt": baseline_time,
                "generatedAt": baseline_time,
                "cards": entries,
            },
        )
        self.record(
            "fixture_started",
            fixtureRoot=str(self.fixture_root),
            canonicalRoot=str(self.canonical_root),
            urls=self.urls,
            serverPids=self.server_pids,
        )

    def fetch_json(self, page: Page, path: str) -> dict[str, Any]:
        return page.evaluate(
            """async path => {
                const response = await fetch(path + (path.includes('?') ? '&' : '?') + 'acceptance=' + Date.now(), {cache:'no-store'});
                let payload = {};
                try { payload = await response.json(); } catch (_) {}
                return {status: response.status, payload};
            }""",
            path,
        )

    def hook(self, page: Page, expression: str) -> Any:
        return page.evaluate(f"window.__samiTestHooks.{expression}")

    def wait_synced(self, page: Page) -> None:
        page.wait_for_function(
            """() => window.__samiTestHooks && document.querySelector('#card-browser-alpha') &&
                document.querySelector('#syncIndicator')?.classList.contains('synced')""",
            timeout=30000,
        )
        page.wait_for_function(
            "() => document.getElementById('splashStatus')?.textContent === 'Ready'",
            timeout=10000,
        )
        page.evaluate(
            """() => {
                const splash = document.getElementById('splash');
                if (!splash) return;
                try { hideSplash(); } catch (_) {}
                // The acceptance harness dismisses the synthetic fixture's loading overlay
                // before pointer coordinates are exercised.
                splash.classList.add('hidden');
            }"""
        )
        page.wait_for_function(
            "() => document.querySelector('#syncIndicator')?.classList.contains('synced')",
            timeout=10000,
        )
        state = self.hook(page, "getSyncIndicatorState()")
        self.check(state["label"] == "Team ESMI synced", "healthy client did not render the synced label", state=state)
        self.check("Sync check failed" not in state["label"], "healthy client rendered the generic sync failure", state=state)
        self.record("healthy_sync", state=state)

    def get_visual_order(self, page: Page) -> dict[str, list[str]]:
        return page.evaluate("window.__samiTestHooks.getVisualOrder()")

    def get_board_order(self, page: Page) -> dict[str, Any]:
        return page.evaluate("window.__samiTestHooks.getBoardOrder()")

    def drag_card(self, page: Page, card_id: str, target_card_id: str | None = None, target_lane: str | None = None) -> None:
        source = page.locator(f"#card-{card_id} [data-order-handle]")
        source.wait_for(state="visible", timeout=10000)
        if target_card_id:
            target = page.locator(f"#card-{target_card_id}")
            target.wait_for(state="visible", timeout=10000)
            target.scroll_into_view_if_needed(timeout=10000)
        elif target_lane:
            target = page.locator(f".column[data-lane-key='{target_lane}']")
            target.wait_for(state="visible", timeout=10000)
            target.scroll_into_view_if_needed(timeout=10000)
        else:
            raise AssertionError("drag needs a target card or lane")
        source.scroll_into_view_if_needed(timeout=10000)
        source_box = source.bounding_box()
        if not source_box:
            raise AssertionError(f"source card has no box: {card_id}")
        target_box = target.bounding_box()
        if not target_box:
            raise AssertionError(f"drag target has no box: {target_card_id or target_lane}")
        start_x = source_box["x"] + source_box["width"] / 2
        start_y = source_box["y"] + source_box["height"] / 2
        if target_card_id:
            target_x = target_box["x"] + target_box["width"] / 2
            target_y = target_box["y"] + 4
        else:
            target_x = target_box["x"] + target_box["width"] / 2
            target_y = target_box["y"] + min(80, target_box["height"] / 2)
        pointer = {"pointerId": 11, "pointerType": "mouse", "isPrimary": True, "button": 0, "buttons": 1, "clientX": start_x, "clientY": start_y, "bubbles": True, "cancelable": True}
        source.dispatch_event("pointerdown", pointer)
        time.sleep(0.45)
        page.locator("body").dispatch_event(
            "pointermove",
            {**pointer, "clientX": start_x + 35, "clientY": start_y + 15},
        )
        page.locator("body").dispatch_event(
            "pointermove",
            {**pointer, "clientX": target_x, "clientY": target_y},
        )
        time.sleep(0.2)
        page.locator("body").dispatch_event(
            "pointerup",
            {**pointer, "buttons": 0, "clientX": target_x, "clientY": target_y},
        )
        page.wait_for_function(
            "() => { const s = window.__samiTestHooks.getDragState(); return s.phase === 'idle' && !s.pending; }",
            timeout=30000,
        )

    def open_edit(self, page: Page, card_id: str) -> None:
        page.locator(f"#card-{card_id} [data-edit='{card_id}']").click()
        page.locator("#drawer.open").wait_for(state="visible", timeout=10000)

    def save_edit(self, page: Page, next_action: str, notes: str | None = None) -> None:
        page.locator("#fNextAction").fill(next_action)
        if notes is not None:
            page.locator("#fNotes").fill(notes)
        page.locator("#saveBtn").click()
        page.wait_for_function(
            "() => !document.getElementById('drawer').classList.contains('open') || document.getElementById('saveBtn').textContent.includes('failed')",
            timeout=30000,
        )

    def direct_card(self, page: Page, card_id: str) -> dict[str, Any]:
        result = self.fetch_json(page, "data/projects.json")
        self.check(result["status"] == 200, "synthetic projects route did not return 200", result=result)
        return next(card for card in result["payload"]["projects"] if str(card["id"]) == card_id)

    def test_board_and_editing(self, page_a: Page, page_b: Page) -> None:
        lane_keys = page_a.locator(".column").evaluate_all("els => els.map(el => el.dataset.laneKey)")
        lane_labels = page_a.locator(".col-header").evaluate_all("els => els.map(el => el.textContent.replace(/\\s+/g, ' ').trim().replace(/\\d+$/, '').trim())")
        self.check(lane_keys == LANES, "board lanes are not exactly the four expected keys", laneKeys=lane_keys)
        labels_without_icons = {expected: any(expected in label for label in lane_labels) for expected in EXPECTED_LANE_LABELS}
        self.check(all(labels_without_icons.values()), "expected lane labels were not rendered", labels=lane_labels, matches=labels_without_icons)
        self.check("Ready" not in " ".join(lane_labels), "legacy Ready lane leaked into the board", labels=lane_labels)
        initial = self.get_visual_order(page_a)
        self.check(initial["backlog"] == ["browser-gamma"], "synthetic backlog order is wrong", order=initial)
        self.check(initial["running"] == ["browser-alpha", "browser-beta"], "synthetic running order is wrong", order=initial)

        beta_handle = page_a.locator("[data-order-handle='browser-beta']")
        beta_handle.press("Alt+ArrowUp")
        page_a.wait_for_function(
            "() => window.__samiTestHooks.getVisualOrder().running.join(',') === 'browser-beta,browser-alpha' && !window.__samiTestHooks.getDragState().pending",
            timeout=30000,
        )
        self.check(self.get_visual_order(page_a)["running"] == ["browser-beta", "browser-alpha"], "keyboard movement failed")
        beta_handle = page_a.locator("[data-order-handle='browser-beta']")
        beta_handle.press("Alt+ArrowDown")
        page_a.wait_for_function(
            "() => window.__samiTestHooks.getVisualOrder().running.join(',') === 'browser-alpha,browser-beta' && !window.__samiTestHooks.getDragState().pending",
            timeout=30000,
        )
        self.check(self.get_visual_order(page_a)["running"] == ["browser-alpha", "browser-beta"], "keyboard restore failed")

        self.drag_card(page_a, "browser-beta", target_card_id="browser-alpha")
        self.check(self.get_visual_order(page_a)["running"] == ["browser-beta", "browser-alpha"], "same-lane drag failed")
        self.drag_card(page_a, "browser-alpha", target_card_id="browser-beta")
        self.check(self.get_visual_order(page_a)["running"] == ["browser-alpha", "browser-beta"], "same-lane drag restore failed")

        self.drag_card(page_a, "browser-alpha", target_card_id="browser-gamma")
        moved = self.get_visual_order(page_a)
        self.check("browser-alpha" in moved["backlog"], "cross-lane drag did not move alpha to backlog", order=moved)
        self.check("browser-alpha" not in moved["running"], "cross-lane drag left alpha in running", order=moved)
        self.drag_card(page_a, "browser-alpha", target_lane="running")
        restored = self.get_visual_order(page_a)
        self.check("browser-alpha" in restored["running"], "cross-lane drag restore failed", order=restored)

        source = page_a.locator("#card-browser-beta [data-order-handle]")
        source_box = source.bounding_box()
        if not source_box:
            raise AssertionError("auto-scroll source has no box")
        start_x = source_box["x"] + source_box["width"] / 2
        start_y = source_box["y"] + source_box["height"] / 2
        pointer = {"pointerId": 17, "pointerType": "mouse", "isPrimary": True, "button": 0, "buttons": 1, "clientX": start_x, "clientY": start_y, "bubbles": True, "cancelable": True}
        page_a.locator("#card-browser-beta [data-order-handle]").dispatch_event("pointerdown", pointer)
        time.sleep(0.45)
        page_a.locator("body").dispatch_event("pointermove", {**pointer, "clientX": start_x + 35, "clientY": start_y + 20})
        page_a.locator("body").dispatch_event("pointermove", {**pointer, "clientX": 640, "clientY": 895})
        time.sleep(0.3)
        auto_scroll = page_a.evaluate("window.__samiTestHooks.getAutoScrollState()")
        self.check(bool(auto_scroll["active"]), "edge drag did not activate auto-scroll", state=auto_scroll)
        page_a.evaluate("cancelPointerCardDrag('Acceptance auto-scroll cancellation')")
        page_a.locator("body").dispatch_event("pointerup", {**pointer, "buttons": 0, "clientX": 640, "clientY": 895})
        page_a.wait_for_function("() => window.__samiTestHooks.getDragState().phase === 'idle'", timeout=10000)
        self.check(page_a.evaluate("window.__samiTestHooks.getDragState().phase") == "idle", "auto-scroll cancellation left a drag active")

        page_a.locator("#boardSearch").fill("Browser Alpha")
        page_a.locator("body.search-active").wait_for(state="attached", timeout=10000)
        disabled = page_a.locator("[data-order-handle]").evaluate_all("els => els.map(el => el.getAttribute('aria-disabled'))")
        self.check(disabled and all(value == "true" for value in disabled), "search did not protect drag handles", handles=disabled)
        page_a.locator("#clearSearchBtn").click()
        page_a.locator("body.search-active").wait_for(state="detached", timeout=10000)
        enabled = page_a.locator("[data-order-handle]").evaluate_all("els => els.map(el => el.getAttribute('aria-disabled'))")
        self.check(enabled and all(value == "false" for value in enabled), "clearing search did not re-enable drag handles", handles=enabled)
        recent = page_a.locator("#recentToggle")
        if recent.count():
            recent.click()
            page_a.locator("body.recent-filter-active").wait_for(state="attached", timeout=10000)
            recent_disabled = page_a.locator("[data-order-handle]").evaluate_all("els => els.map(el => el.getAttribute('aria-disabled'))")
            self.check(all(value == "true" for value in recent_disabled), "recent filter did not protect drag handles")
            recent.click()
            page_a.locator("body.recent-filter-active").wait_for(state="detached", timeout=10000)

        notes = "First line\n\nSecond line — apostrophe ' and markdown *literal* <b>not HTML</b>"
        for action in ["Acceptance action one — α", "Acceptance action two\nwith multiline next action", "", "Acceptance reset action"]:
            self.open_edit(page_a, "browser-alpha")
            self.save_edit(page_a, action, notes if action == "Acceptance action one — α" else None)
            wait_until(
                lambda: self.direct_card(page_a, "browser-alpha").get("nextAction") == action.strip(),
                timeout=20,
                message=f"card save did not persist Next Action {action!r}",
            )
        alpha = self.direct_card(page_a, "browser-alpha")
        history = alpha.get("projectHistory") or []
        history_types = [str(item.get("type")) for item in history]
        self.check("next_action_changed" in history_types, "Next Action change history is missing", history=history_types)
        self.check("next_action_cleared" in history_types, "Next Action clear history is missing", history=history_types)
        self.check("next_action_set" in history_types, "Next Action reset/set history is missing", history=history_types)
        self.check(alpha.get("notes") == notes, "Additional Notes were not preserved exactly", actual=alpha.get("notes"))
        self.check(alpha.get("olderClientField") == "preserve-this-older-client-field", "older-client field was dropped during save")
        self.check(alpha.get("legacyField", {}).get("source") == "older-client", "legacy object field was dropped during save")

        page_a.locator("[data-details='browser-alpha']").click()
        page_a.locator("[data-details-panel-for='browser-alpha']").wait_for(state="visible", timeout=10000)
        details_text = page_a.locator("[data-details-panel-for='browser-alpha']").inner_text()
        self.check("Project Update History" in details_text, "Project Update History was not rendered")
        self.check("Additional Notes" in details_text, "Additional Notes disclosure was not rendered")
        page_a.screenshot(path=str(self.artifact_root / "drag-history.png"), full_page=True)

        page_a.locator("[data-copy-context='browser-alpha']").click()
        context_text = page_a.evaluate("navigator.clipboard ? navigator.clipboard.readText() : Promise.resolve('')")
        if not context_text:
            fallback = page_a.locator("#copyContextText")
            context_text = fallback.input_value() if fallback.count() else ""
        self.check("# SAMI Project Context" in context_text, "Project Context output did not contain its Markdown heading")
        self.check("Browser Alpha" in context_text and "Acceptance reset action" in context_text, "Project Context omitted synthetic card content")
        self.check("First line" in context_text and "not HTML" in context_text, "Project Context omitted Notes content")
        page_a.locator("#copyContextFallback #copyContextClose").click(timeout=1000) if page_a.locator("#copyContextFallback #copyContextClose").count() else None

    def test_edit_conflict(self, page_a: Page, page_b: Page) -> None:
        page_b.evaluate("requestSyncCheck()")
        page_b.wait_for_timeout(3000)
        stale_status = self.fetch_json(page_a, "api/sync-status")["payload"]
        self.open_edit(page_a, "browser-alpha")
        page_a.locator("#fNotes").fill("Client A stale edit")
        self.open_edit(page_b, "browser-alpha")
        self.save_edit(page_b, "Acceptance reset action", "Client B canonical conflict edit")
        wait_until(
            lambda: self.direct_card(page_b, "browser-alpha").get("notes") == "Client B canonical conflict edit",
            timeout=20,
            message="Client B conflict edit did not persist",
        )
        page_a.route(
            "**/api/sync-status*",
            lambda route: route.fulfill(status=200, content_type="application/json", body=json.dumps(stale_status)),
        )
        page_a.locator("#saveBtn").click()
        page_a.wait_for_function(
            "() => document.getElementById('notice').classList.contains('error') && document.getElementById('notice').textContent.includes('Save failed')",
            timeout=30000,
        )
        page_a.unroute("**/api/sync-status*")
        notice = page_a.locator("#notice").text_content() or ""
        conflict_responses = [
            item
            for item in self.response_errors
            if int(item.get("status", 0)) == 409 and "/api/projects" in str(item.get("url", ""))
        ]
        self.check(
            "Save failed" in notice
            and any(marker in notice.lower() for marker in ("source changed", "refresh the board", "canonical")),
            "edit conflict did not show the truthful stale-save message",
            notice=notice,
        )
        self.check(conflict_responses, "edit conflict did not produce the deliberate HTTP 409", notice=notice)
        page_a.locator("#cancelBtn").click()
        page_a.wait_for_function("() => !document.getElementById('drawer').classList.contains('open')", timeout=10000)

    def test_file_detection(self, page_a: Page) -> None:
        if not self.canonical_root:
            raise AssertionError("canonical root was not seeded")
        baseline = self.fetch_json(page_a, "data/project_file_index.json")["payload"]
        baseline_entry = next(entry for entry in baseline.get("cards", []) if entry.get("cardId") == "browser-alpha")
        self.check(int(baseline_entry.get("fileCount", 0)) == 0, "synthetic file baseline was not empty", entry=baseline_entry)
        folder = self.canonical_root / "project_files" / "browser-alpha"
        (folder / "00_Admin").mkdir(parents=True, exist_ok=True)
        (folder / "01_Planning").mkdir(parents=True, exist_ok=True)
        (folder / "00_Admin" / "stable-one.txt").write_text("stable one\n", encoding="utf-8")
        (folder / "01_Planning" / "stable-two.md").write_text("# stable two\n", encoding="utf-8")
        (folder / "00_Admin" / "~$ignored.docx").write_text("temporary office lock", encoding="utf-8")
        (folder / "ignore.tmp").write_text("temporary", encoding="utf-8")
        self.record("synthetic_files_created", folder=str(folder))

        def scan_state() -> dict[str, Any]:
            return self.fetch_json(page_a, "api/sync-state")["payload"]

        wait_until(
            lambda: (
                scan_state()
                and
                next(
                    (entry for entry in self.fetch_json(page_a, "data/project_file_index.json")["payload"].get("cards", []) if entry.get("cardId") == "browser-alpha"),
                    {},
                ).get("fileCount", 0)
                == 2
            ),
            timeout=35,
            interval=2,
            message="stable synthetic files were not indexed after the two-pass scan",
        )
        indexed = self.fetch_json(page_a, "data/project_file_index.json")["payload"]
        entry = next(entry for entry in indexed.get("cards", []) if entry.get("cardId") == "browser-alpha")
        files = entry.get("files") or []
        paths = sorted(str(item.get("relativePath")) for item in files)
        self.check(paths == ["00_Admin/stable-one.txt", "01_Planning/stable-two.md"], "file baseline included an ignored/temp file", paths=paths)
        self.check(int(entry.get("adminCount", 0)) == 1 and int(entry.get("planningCount", 0)) == 1, "multi-folder file counts were not grouped correctly", entry=entry)
        fingerprints = [str(item.get("fingerprint")) for item in files]
        self.check(len(fingerprints) == len(set(fingerprints)) == 2, "indexed files were not deduplicated by fingerprint", fingerprints=fingerprints)
        audit_text = (self.canonical_root / "data" / "card_updates.jsonl").read_text(encoding="utf-8")
        audit_events = [json.loads(line) for line in audit_text.splitlines() if line.strip()]
        file_events = [event for event in audit_events if event.get("action") == "project_file_added" and event.get("cardId") == "browser-alpha"]
        self.check(len(file_events) == 1 and int(file_events[0].get("fileCount", 0)) == 2, "multi-file grouping did not produce one grouped audit event", events=file_events)
        scan_state()
        time.sleep(8)
        indexed_again = self.fetch_json(page_a, "data/project_file_index.json")["payload"]
        entry_again = next(entry for entry in indexed_again.get("cards", []) if entry.get("cardId") == "browser-alpha")
        self.check(len(entry_again.get("files") or []) == 2, "repeat scan duplicated indexed files")
        audit_text_again = (self.canonical_root / "data" / "card_updates.jsonl").read_text(encoding="utf-8")
        audit_events_again = [json.loads(line) for line in audit_text_again.splitlines() if line.strip()]
        self.check(len([event for event in audit_events_again if event.get("action") == "project_file_added" and event.get("cardId") == "browser-alpha"]) == 1, "repeat scan duplicated file history event")

    def test_chimes_and_remote_sync(self, page_a: Page, page_b: Page) -> None:
        for page in (page_a, page_b):
            page.evaluate(
                """() => {
                    window.__acceptanceChimes = [];
                    const original = window.playUpdateChime;
                    window.playUpdateChime = function(volume, source) {
                        window.__acceptanceChimes.push({at: performance.now(), volume, source});
                        return original(volume, source);
                    };
                }"""
            )
        off = page_a.evaluate(
            """() => {
                setSoundPref('off');
                window.__samiTestHooks.resetSoundMetrics();
                window.__acceptanceChimes = [];
                markSoundReady();
                playUpdateChime(soundVolume(), 'local');
                return {volume: soundVolume(), metrics: window.__samiTestHooks.getSoundMetrics(), calls: window.__acceptanceChimes};
            }"""
        )
        self.check(
            off["volume"] == 0
            and off["metrics"]["localChimes"] == 0
            and not [call for call in off["calls"] if float(call.get("volume", 0)) > 0],
            "Off chime preference did not suppress sound",
            result=off,
        )
        for preference, expected in [("low", 0.08), ("normal", 0.18)]:
            result = page_a.evaluate(
                """preference => {
                    setSoundPref(preference);
                    window.__samiTestHooks.resetSoundMetrics();
                    window.__acceptanceChimes = [];
                    markSoundReady();
                    playUpdateChime(soundVolume(), 'local');
                    return {volume: soundVolume(), metrics: window.__samiTestHooks.getSoundMetrics(), calls: window.__acceptanceChimes};
                }""",
                preference,
            )
            self.check(abs(float(result["volume"]) - expected) < 0.001, f"{preference} chime volume contract changed", result=result)
            self.check(result["calls"] or result["metrics"]["localChimes"] > 0, f"{preference} chime invocation path was not reached", result=result)

        baseline = clone_lanes(self.get_board_order(page_a)["lanes"])
        baseline["running"] = ["browser-alpha", "browser-beta"]
        baseline_result = page_a.evaluate(
            """async lanes => await submitBoardOrder(lanes, {movedCardId:'browser-alpha', auditAction:'card_reordered', localFeedback:true})""",
            baseline,
        )
        self.check(baseline_result is True, "could not establish the remote-sync baseline order")
        baseline_state = self.get_board_order(page_a)
        page_b.evaluate("requestSyncCheck()")
        wait_until(
            lambda: (
                self.get_visual_order(page_b)["running"] == ["browser-alpha", "browser-beta"]
                and self.get_board_order(page_b).get("revision") == baseline_state.get("revision")
                and self.get_board_order(page_b).get("changeId") == baseline_state.get("changeId")
            ),
            timeout=20,
            message="Client B did not settle on the remote-sync baseline order",
        )
        page_b.evaluate("flushRemoteNotifications()")
        page_a.evaluate("setSoundPref('low'); markSoundReady(); flushRemoteNotifications(); window.__samiTestHooks.resetSoundMetrics(); window.__acceptanceChimes = []")
        page_b.evaluate("setSoundPref('low'); markSoundReady(); flushRemoteNotifications(); window.__samiTestHooks.resetSoundMetrics(); window.__acceptanceChimes = []")
        page_a.wait_for_timeout(750)
        page_b.wait_for_timeout(750)
        page_a.evaluate("window.__samiTestHooks.resetSoundMetrics(); window.__acceptanceChimes = []")
        page_b.evaluate("window.__samiTestHooks.resetSoundMetrics(); window.__acceptanceChimes = []")
        page_b.evaluate(
            """() => {
                window.__acceptanceRenderAt = 0;
                window.__acceptanceRenderArmed = false;
                const board = document.getElementById('board');
                window.__acceptanceObserver = new MutationObserver(() => {
                    if (window.__acceptanceRenderArmed && !window.__acceptanceRenderAt) window.__acceptanceRenderAt = performance.now();
                });
                window.__acceptanceObserver.observe(board, {childList: true, subtree: true});
            }"""
        )
        current = self.get_board_order(page_a)["lanes"]
        next_lanes = swap_first_two(current, "running")
        page_b.evaluate("window.__acceptanceRenderArmed = true")
        result = page_a.evaluate(
            """async lanes => await submitBoardOrder(lanes, {movedCardId:'browser-beta', auditAction:'card_reordered', localFeedback:true})""",
            next_lanes,
        )
        self.check(result is True, "Client A could not submit the remote-sync order mutation")
        page_b.wait_for_function("() => window.__acceptanceRenderAt > 0", timeout=20000)
        b_render_at = page_b.evaluate("window.__acceptanceRenderAt")
        try:
            page_b.wait_for_function(
                "() => window.__acceptanceChimes.some(call => call.source === 'remote') || window.__samiTestHooks.getSoundMetrics().remoteChimes > 0",
                timeout=5000,
            )
        except PlaywrightTimeoutError:
            pass
        b_calls = page_b.evaluate("window.__acceptanceChimes")
        b_metrics = page_b.evaluate("window.__samiTestHooks.getSoundMetrics()")
        self.check(self.get_visual_order(page_b)["running"] == ["browser-beta", "browser-alpha"], "Client B did not remotely render the order update")
        remote_calls = [call for call in b_calls if call.get("source") == "remote"]
        self.check(remote_calls or b_metrics["remoteChimes"] > 0, "remote chime invocation path was not reached", calls=b_calls, metrics=b_metrics)
        if remote_calls:
            self.check(b_render_at <= remote_calls[0]["at"], "remote render did not occur before the remote chime", renderAt=b_render_at, chimeAt=remote_calls[0]["at"])
        self.check(page_a.evaluate("window.__samiTestHooks.getSoundMetrics()")["remoteChimes"] == 0, "originating client played a self-echo remote chime")
        self.record("remote_sync_and_chime", clientBRenderAt=b_render_at, clientBCalls=b_calls, clientBMetrics=b_metrics)
        page_b.evaluate("window.__acceptanceObserver && window.__acceptanceObserver.disconnect()")

    def test_conflicting_order(self, page_a: Page, page_b: Page) -> None:
        page_b.evaluate("requestSyncCheck()")
        page_b.wait_for_timeout(3000)
        page_a.route(
            "**/api/sync-state*",
            lambda route: route.fulfill(
                status=200,
                content_type="application/json",
                body=json.dumps({
                    "ok": True,
                    "canonicalAvailable": True,
                    "mode": "team-canonical",
                    "projectsRevision": "stale-acceptance-revision",
                    "projectsSignature": "stale-acceptance-signature",
                    "boardOrderRevision": 1,
                    "boardOrderChangeId": "stale-acceptance-order",
                    "boardOrderSignature": "stale-order|1",
                    "latestAuditSignature": "stale-audit|1",
                    "projectFileIndexRevision": 1,
                    "projectFileIndexSignature": "stale-index|1",
                }),
            ),
        )
        page_a_order = self.get_board_order(page_a)
        stale_lanes = swap_first_two(page_a_order["lanes"], "running")
        b_result = page_b.evaluate(
            """async () => {
                const state = await fetch('api/board-order?acceptance=' + Date.now(), {cache:'no-store'}).then(r => r.json());
                const lanes = JSON.parse(JSON.stringify(state.lanes));
                lanes.running = lanes.running.slice().reverse();
                return await submitBoardOrder(lanes, {movedCardId:'browser-beta', auditAction:'card_reordered', localFeedback:false});
            }"""
        )
        self.check(b_result is True, "Client B could not create the deliberate competing board-order update")
        a_result = page_a.evaluate(
            """async lanes => await submitBoardOrder(lanes, {movedCardId:'browser-alpha', auditAction:'card_reordered', localFeedback:true})""",
            stale_lanes,
        )
        self.check(a_result is False, "stale drag-order submission unexpectedly succeeded")
        notice = page_a.locator("#notice").text_content() or ""
        self.check("board order" in notice.lower(), "deliberate drag conflict did not report a board-order conflict", notice=notice)
        page_a.unroute("**/api/sync-state*")

    def test_disconnect_reconnect(self, page_a: Page, page_b: Page) -> None:
        unavailable = {"ok": True, "canonicalAvailable": False, "mode": "offline", "projectsRevision": "", "projectsSignature": "", "boardOrderRevision": 0, "boardOrderChangeId": "", "boardOrderSignature": "", "latestAuditSignature": "", "projectFileIndexRevision": 0, "projectFileIndexSignature": ""}
        page_a.route("**/api/sync-state*", lambda route: route.fulfill(status=200, content_type="application/json", body=json.dumps(unavailable)))
        page_a.evaluate("requestSyncCheck()")
        page_a.wait_for_function("() => document.getElementById('syncIndicator').classList.contains('offline')", timeout=10000)
        offline = self.hook(page_a, "getSyncIndicatorState()")
        self.check(offline["label"] == "Team ESMI unavailable", "canonical unavailable did not render the unavailable state", state=offline)
        self.check("Sync check failed" not in offline["label"], "canonical unavailable was collapsed into generic failure", state=offline)
        page_a.screenshot(path=str(self.artifact_root / "canonical-unavailable.png"), full_page=True)
        page_a.unroute("**/api/sync-state*")
        page_a.evaluate("document.activeElement && document.activeElement.blur(); requestSyncCheck()")
        try:
            page_a.wait_for_function("() => document.getElementById('syncIndicator').classList.contains('synced')", timeout=15000)
        except PlaywrightTimeoutError:
            debug = page_a.evaluate(
                """async () => {
                    const statusResponse = await fetch('api/sync-status?acceptanceDebug=' + Date.now(), {cache:'no-store'});
                    const status = await statusResponse.json();
                    const stateResponse = await fetch('api/sync-state?acceptanceDebug=' + Date.now(), {cache:'no-store'});
                    const state = await stateResponse.json();
                    return {
                        indicator: window.__samiTestHooks.getSyncIndicatorState(),
                        activeElement: document.activeElement ? {tag: document.activeElement.tagName, id: document.activeElement.id, type: document.activeElement.type || ''} : null,
                        sync: {isEditing: appState.sync.isEditing, syncInFlight: appState.sync.syncInFlight, pending: appState.sync.pending, lastError: appState.sync.lastError, lastNormalised: appState.sync.lastNormalised ? {healthState: appState.sync.lastNormalised.healthState, syncHealthy: appState.sync.lastNormalised.syncHealthy, comparisons: appState.sync.lastNormalised.comparisons} : null},
                        statusNormalised: normaliseSyncState(status),
                        stateNormalised: normaliseSyncState(state)
                    };
                }"""
            )
            self.record("reconnect_debug", debug=debug)
            raise
        recovered = self.hook(page_a, "getSyncIndicatorState()")
        self.check(recovered["label"] == "Team ESMI synced", "reconnect did not restore the healthy state", state=recovered)
        page_a.screenshot(path=str(self.artifact_root / "sync-recovered.png"), full_page=True)

        failure_payload = {"ok": False, "error": "synthetic deliberate disconnect"}
        self.intentional_failure_urls.add("/api/sync-state")
        page_b.route("**/api/sync-state*", lambda route: route.fulfill(status=503, content_type="application/json", body=json.dumps(failure_payload)))
        page_b.evaluate("requestSyncCheck()")
        page_b.wait_for_function("() => document.getElementById('syncIndicator').classList.contains('error')", timeout=10000)
        failed = self.hook(page_b, "getSyncIndicatorState()")
        self.check(failed["label"] == "Sync check failed", "HTTP sync failure did not render a truthful failure state", state=failed)
        page_b.unroute("**/api/sync-state*")
        page_b.evaluate("requestSyncCheck()")
        page_b.wait_for_function("() => document.getElementById('syncIndicator').classList.contains('synced')", timeout=15000)

    def export_meeting_pack(self, page: Page, fmt: str) -> Path:
        page.locator("#meetingPackBtn").click()
        page.locator("#meetingPackModal.open").wait_for(state="visible", timeout=10000)
        page.locator("#meetingPackFormat").select_option(fmt)
        with page.expect_download(timeout=40000) as download_info:
            with page.expect_response(lambda response: "/api/meeting-pack/export" in response.url and response.request.method == "POST", timeout=40000) as response_info:
                page.locator("#meetingPackAuthorised").click()
        response = response_info.value
        download = download_info.value
        output = self.artifact_root / f"SAMI_Meeting_Pack_browser.{fmt}"
        download.save_as(str(output))
        content_type = response.headers.get("content-type", "")
        disposition = response.headers.get("content-disposition", "")
        body = output.read_bytes()
        result = {
            "status": response.status,
            "contentType": content_type,
            "contentDisposition": disposition,
            "suggestedFilename": download.suggested_filename,
            "path": str(output),
            "length": len(body),
            "signature": body[:8].decode("latin-1", errors="replace"),
        }
        self.downloads[fmt] = result
        self.check(response.status == 200, f"{fmt} Meeting Pack route did not return HTTP 200", result=result)
        self.check(len(body) > 100, f"{fmt} Meeting Pack download was empty", result=result)
        self.check("Meeting Pack generated." in (page.locator("#meetingPackStatus").text_content() or ""), f"{fmt} Meeting Pack UI did not report success")
        if fmt == "pdf":
            self.check(body.startswith(b"%PDF-"), "browser PDF download did not have a valid PDF signature", result=result)
            self.check("application/pdf" in content_type.lower(), "browser PDF content type was incorrect", result=result)
            self.check(".pdf" in (download.suggested_filename or "").lower(), "browser PDF filename was incorrect", result=result)
            page.screenshot(path=str(self.artifact_root / "pdf-export.png"), full_page=True)
        elif fmt == "md":
            self.check("markdown" in content_type.lower() or "text/plain" in content_type.lower(), "browser Markdown content type changed", result=result)
        elif fmt == "xlsx":
            self.check(body[:2] == b"PK", "browser Excel download was not an XLSX package", result=result)
        page.locator("#meetingPackCancel").click()
        return output

    def test_meeting_pack(self, page_a: Page) -> None:
        self.export_meeting_pack(page_a, "pdf")
        self.export_meeting_pack(page_a, "md")
        self.export_meeting_pack(page_a, "xlsx")
        self.record("meeting_pack_exports", downloads=self.downloads)

    def classify_errors(self) -> dict[str, Any]:
        expected_response_errors: list[dict[str, Any]] = []
        unexpected_response_errors: list[dict[str, Any]] = []
        for item in self.response_errors:
            url = item["url"]
            path = url.split("?", 1)[0]
            status = int(item["status"])
            expected = False
            reason = ""
            if status == 404 and any(marker in path for marker in ("kanban_config.json", "card_activity_index.json", "project_file_index.json")):
                expected, reason = True, "optional legacy/config index"
            elif status == 409:
                expected, reason = True, "deliberate conflict test"
            elif status == 503 and "/api/sync-state" in path:
                expected, reason = True, "deliberate disconnect test"
            if expected:
                expected_response_errors.append({**item, "reason": reason})
            else:
                unexpected_response_errors.append(item)
        unexpected_console: list[dict[str, Any]] = []
        expected_console_statuses = {
            client: {int(item["status"]) for item in expected_response_errors if item["client"] == client}
            for client in {item["client"] for item in expected_response_errors}
        }
        for client, entries in self.console_logs.items():
            for entry in entries:
                text = str(entry.get("text", ""))
                kind = str(entry.get("type", ""))
                if kind == "pageerror":
                    unexpected_console.append({"client": client, **entry})
                elif kind == "error":
                    if "Failed to load resource" in text:
                        status_match = re.search(r"status of (\d{3})", text)
                        if status_match and int(status_match.group(1)) in expected_console_statuses.get(client, set()):
                            continue
                    unexpected_console.append({"client": client, **entry})
        result = {
            "expectedResponseErrors": expected_response_errors,
            "unexpectedResponseErrors": unexpected_response_errors,
            "networkFailures": self.network_failures,
            "unexpectedConsoleErrors": unexpected_console,
        }
        self.check(not unexpected_response_errors, "unexpected HTTP errors were observed", errors=unexpected_response_errors)
        self.check(not unexpected_console, "unexplained console/page errors were observed", errors=unexpected_console)
        return result

    def write_artifacts(self, result: dict[str, Any]) -> None:
        write_json(self.artifact_root / "telemetry.json", self.telemetry)
        write_json(self.artifact_root / "console_logs.json", self.console_logs)
        write_json(self.artifact_root / "network_failures.json", self.network_failures)
        summary = {
            "status": "GREEN",
            "assertions": self.assertions,
            "artifactRoot": str(self.artifact_root),
            "fixtureRoot": str(self.fixture_root),
            "canonicalRoot": str(self.canonical_root) if self.canonical_root else "",
            "urls": self.urls,
            "serverPids": self.server_pids,
            "browser": self.browser_versions,
            "downloads": self.downloads,
            "errorClassification": result,
            "screenshots": [str(path) for path in sorted(self.artifact_root.glob("*.png"))],
            "videos": [str(path) for path in sorted(self.artifact_root.glob("video-*/*.webm"))],
            "traces": [str(path) for path in sorted(self.artifact_root.glob("*.zip"))],
        }
        write_json(self.artifact_root / "summary.json", summary)
        self.record("acceptance_complete", status="GREEN", assertions=self.assertions)
        write_json(self.artifact_root / "telemetry.json", self.telemetry)

    def run(self) -> dict[str, Any]:
        if not CHROME.is_file():
            raise RuntimeError(f"Chrome executable not found: {CHROME}")
        self.artifact_root.mkdir(parents=True, exist_ok=True)
        self.seed_fixture()
        try:
            with sync_playwright() as playwright:
                context_a = playwright.chromium.launch_persistent_context(
                    str(self.artifact_root / "chrome-profile-a"),
                    headless=True,
                    executable_path=str(CHROME),
                    viewport={"width": 1365, "height": 900},
                    accept_downloads=True,
                    record_video_dir=str(self.artifact_root / "video-a"),
                    args=["--no-sandbox", "--disable-gpu"],
                )
                context_b = playwright.chromium.launch_persistent_context(
                    str(self.artifact_root / "chrome-profile-b"),
                    headless=True,
                    executable_path=str(CHROME),
                    viewport={"width": 1365, "height": 900},
                    accept_downloads=True,
                    record_video_dir=str(self.artifact_root / "video-b"),
                    args=["--no-sandbox", "--disable-gpu"],
                )
                page_a = context_a.pages[0] if context_a.pages else context_a.new_page()
                page_b = context_b.pages[0] if context_b.pages else context_b.new_page()
                self.attach_page_logging(page_a, "Client A")
                self.attach_page_logging(page_b, "Client B")
                context_a.tracing.start(screenshots=True, snapshots=True, sources=True)
                context_b.tracing.start(screenshots=True, snapshots=True, sources=True)
                self.browser_versions = {
                    "playwright": importlib.metadata.version("playwright"),
                    "clientA": playwright.chromium.executable_path if hasattr(playwright.chromium, "executable_path") else str(CHROME),
                    "chromeExecutable": str(CHROME),
                    "browserVersion": context_a.browser.version,
                }
                page_a.goto(self.urls["Client A"], wait_until="domcontentloaded", timeout=30000)
                page_b.goto(self.urls["Client B"], wait_until="domcontentloaded", timeout=30000)
                context_a.grant_permissions(["clipboard-read", "clipboard-write"], origin=self.urls["Client A"].split("/?", 1)[0])
                self.wait_synced(page_a)
                self.wait_synced(page_b)
                page_a.screenshot(path=str(self.artifact_root / "healthy-sync.png"), full_page=True)
                self.test_board_and_editing(page_a, page_b)
                self.test_chimes_and_remote_sync(page_a, page_b)
                self.test_edit_conflict(page_a, page_b)
                self.test_conflicting_order(page_a, page_b)
                self.test_file_detection(page_a)
                self.test_disconnect_reconnect(page_a, page_b)
                self.test_meeting_pack(page_a)
                classification = self.classify_errors()
                context_a.tracing.stop(path=str(self.artifact_root / "client-a-trace.zip"))
                context_b.tracing.stop(path=str(self.artifact_root / "client-b-trace.zip"))
                context_a.close()
                context_b.close()
        finally:
            for pid in self.server_pids:
                stop_process(pid)
        result = {"status": "GREEN", "assertions": self.assertions}
        self.write_artifacts(classification)
        print(json.dumps({**result, "artifactRoot": str(self.artifact_root)}, ensure_ascii=False))
        print("BROWSER_ACCEPTANCE_GREEN")
        return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact-root", type=Path, default=None)
    args = parser.parse_args()
    artifact_root = args.artifact_root or Path(os.environ.get("TEMP", ".")) / f"SAMI-browser-acceptance-{int(time.time())}"
    run = AcceptanceRun(artifact_root)
    try:
        run.run()
        return 0
    except Exception as exc:
        run.record("acceptance_failed", error=str(exc), assertions=run.assertions)
        write_json(run.artifact_root / "telemetry.json", run.telemetry)
        write_json(run.artifact_root / "console_logs.json", run.console_logs)
        write_json(run.artifact_root / "network_failures.json", run.network_failures)
        write_json(
            run.artifact_root / "summary.json",
            {"status": "RED", "assertions": run.assertions, "artifactRoot": str(run.artifact_root), "error": str(exc)},
        )
        print(f"BROWSER_ACCEPTANCE_RED: {exc}", file=sys.stderr)
        print(f"ARTIFACT_ROOT={run.artifact_root}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
