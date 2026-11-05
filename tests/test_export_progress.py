"""History progress is opt-in, content-free, cancellable and transport-only."""

import contextlib
import io
import json
import sys
import threading
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin"))
import teams4e_graph as backend


class ExportProgressTests(unittest.TestCase):
  def test_export_reports_pages_auth_and_cache_without_message_content(self):
    updates = []
    context = backend.EXPORT_PROGRESS.set(updates.append)
    try:
      with (mock.patch.object(backend, "mock_enabled", return_value=False),
            mock.patch.object(backend, "ensure_graph_token", return_value="fixture-token"),
            mock.patch.object(backend, "graph_json", side_effect=[
                {"value": [{"id": "private-id"}], "@odata.nextLink": "/older"},
                {"value": [{"id": "older-private-id"}]},
            ]), mock.patch.object(backend, "TeamsCache")):
        result, _ = backend.execute(
            ["teams", "chat", "message", "export", "--chatId", "private-chat"])
      self.assertTrue(result["history"]["complete"])
      self.assertEqual([
          {"stage": "auth"},
          {"stage": "download", "pages": 1, "messages": 1},
          {"stage": "download", "pages": 2, "messages": 2},
          {"stage": "cache"},
      ], updates)
      self.assertNotIn("private", json.dumps(updates))
      self.assertNotIn("fixture-token", json.dumps(updates))
    finally:
      backend.EXPORT_PROGRESS.reset(context)

  def test_throttle_and_retry_keep_numeric_wait_and_existing_budget(self):
    updates = []
    context = backend.EXPORT_PROGRESS.set(updates.append)
    try:
      with (mock.patch.object(backend, "GRAPH_REQUEST_BUDGET") as budget,
            mock.patch.object(backend.urllib.request, "urlopen", side_effect=[
                urllib.error.HTTPError("fixture", 429, "limited", {"Retry-After": "12"},
                                       io.BytesIO(b'{}')),
                io.BytesIO(b'{"value":[]}'),
            ])):
        self.assertEqual({"value": []}, backend.graph_json("/chats", "private-token"))
      budget.defer.assert_called_once_with(12.0)
      self.assertIn({"stage": "throttle", "retryAfterSeconds": 12.0}, updates)
      self.assertNotIn("private-token", json.dumps(updates))
    finally:
      backend.EXPORT_PROGRESS.reset(context)

  def test_shared_budget_reports_wait_without_changing_scheduling(self):
    updates = []
    now = [0.0]
    context = backend.EXPORT_PROGRESS.set(updates.append)
    try:
      def sleep(seconds):
        now[0] += seconds

      budget = backend.GraphRequestBudget(limit=1, window=10, clock=lambda: now[0], sleep=sleep)
      budget.acquire()
      budget.acquire()
      self.assertEqual([{"stage": "throttle", "retryAfterSeconds": 10.0}], updates)
      self.assertEqual(10.0, now[0])
    finally:
      backend.EXPORT_PROGRESS.reset(context)

  def test_export_can_cancel_between_pages(self):
    event = threading.Event()
    cancel = backend.READ_CANCEL.set(event)
    progress = backend.EXPORT_PROGRESS.set(lambda _: event.set())
    try:
      with mock.patch.object(backend, "graph_json", return_value={
          "value": [{"id": "one"}], "@odata.nextLink": "/older",
      }) as request:
        with self.assertRaises(backend.ReadCancelled):
          backend.export_message_history("fixture", "token")
        self.assertEqual(1, request.call_count)
    finally:
      backend.EXPORT_PROGRESS.reset(progress)
      backend.READ_CANCEL.reset(cancel)

  def test_server_progress_is_isolated_to_opted_in_exports(self):
    def execute(args, **kwargs):
      backend.export_progress("download", pages=2, messages=80)
      return {"history": {"complete": True}}, "json"

    requests = [
        {"id": 1, "args": ["teams", "chat", "message", "export"], "progress": True},
        {"id": 2, "args": ["teams", "chat", "message", "export"]},
        {"id": 3, "args": ["teams", "chat", "message", "list"], "progress": True},
    ]
    output = io.StringIO()
    with (mock.patch.object(backend.sys, "stdin", map(json.dumps, requests)),
          mock.patch.object(backend, "execute", side_effect=execute),
          contextlib.redirect_stdout(output)):
      backend.serve()
    responses = [json.loads(line) for line in output.getvalue().splitlines()]
    progress = [item for item in responses if item.get("progress")]
    self.assertEqual([{"id": 1, "ok": True, "progress": True,
                       "result": {"stage": "download", "pages": 2, "messages": 80}}], progress)
    self.assertEqual(3, len([item for item in responses if not item.get("progress")]))
    self.assertIsNone(backend.EXPORT_PROGRESS.get())

  def test_server_cancels_full_export_without_affecting_mutations(self):
    started, finished = threading.Event(), threading.Event()

    def execute(args, **kwargs):
      self.assertIsNotNone(backend.READ_CANCEL.get())
      started.set()
      try:
        backend.read_wait(2)
        self.fail("Export ignored cancellation")
      finally:
        finished.set()

    def requests():
      yield json.dumps({"id": 1, "args": ["teams", "chat", "message", "export"]})
      self.assertTrue(started.wait(2))
      yield '{"cancel": 1}'
      self.assertTrue(finished.wait(2))

    output = io.StringIO()
    with (mock.patch.object(backend.sys, "stdin", requests()),
          mock.patch.object(backend, "execute", side_effect=execute),
          contextlib.redirect_stdout(output)):
      backend.serve()
    self.assertEqual("", output.getvalue())


if __name__ == "__main__":
  unittest.main()
