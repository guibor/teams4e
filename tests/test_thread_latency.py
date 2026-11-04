"""Thread-loading latency regressions without a company account."""

import contextlib
import io
import json
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin"))
import teams4e_graph as backend
from teams4e_cache import TeamsCache


class ThreadLatencyTests(unittest.TestCase):
  def test_chat_opens_while_six_background_workers_are_blocked(self):
    started = [threading.Event() for _ in range(8)]
    release = threading.Event()
    opened = threading.Event()

    def execute(args, **kwargs):
      if args[0] == "background":
        started[int(args[1])].set()
        if not release.wait(5):
          raise AssertionError("Background fixture timed out")
      elif "--limit" in args:
        opened.set()
      else:
        self.assertTrue(release.is_set(), "Unbounded history used a reserved reader slot")
      return [], "json"

    def requests():
      try:
        for i in range(8):
          yield json.dumps({"id": i, "args": ["background", str(i)]})
        self.assertTrue(all(event.wait(2) for event in started[:6]))
        # An unbounded history read queues with background work, not the reader.
        yield json.dumps({"id": 8, "args": ["teams", "chat", "message", "list"]})
        yield json.dumps({"id": 9, "args": ["teams", "chat", "message", "list",
                                            "--limit", "50"]})
        self.assertTrue(opened.wait(2), "Thread queued behind background work")
      finally:
        release.set()

    output = io.StringIO()
    with (mock.patch.object(backend.sys, "stdin", requests()),
          mock.patch.object(backend, "execute", side_effect=execute),
          contextlib.redirect_stdout(output)):
      backend.serve()
    rows = [json.loads(line) for line in output.getvalue().splitlines()]
    self.assertTrue(all(row["ok"] for row in rows))
    self.assertEqual(10, len(rows))

  def test_cancelled_queued_foreground_read_never_executes(self):
    started = [threading.Event(), threading.Event()]
    release = threading.Event()
    executed = []

    def execute(args, **kwargs):
      index = int(args[-1])
      executed.append(index)
      if index < 2:
        started[index].set()
        if not release.wait(5):
          raise AssertionError("Reader fixture timed out")
      return [], "json"

    def requests():
      try:
        for i in range(3):
          if i == 2:
            self.assertTrue(all(event.wait(2) for event in started))
          yield json.dumps({"id": i, "args": ["teams", "chat", "message", "list",
                                              "--limit", "50", "--chatId", str(i)]})
        yield '{"cancel":2}'
      finally:
        release.set()

    output = io.StringIO()
    with (mock.patch.object(backend.sys, "stdin", requests()),
          mock.patch.object(backend, "execute", side_effect=execute),
          contextlib.redirect_stdout(output)):
      backend.serve()
    self.assertEqual([0, 1], sorted(executed))
    self.assertEqual({0, 1}, {json.loads(line)["id"] for line in output.getvalue().splitlines()})

  def test_open_existing_cache_does_not_write(self):
    with tempfile.TemporaryDirectory() as directory:
      path = Path(directory) / "fixture.sqlite3"
      with TeamsCache(path):
        pass
      with TeamsCache(path) as cache:
        self.assertEqual(0, cache.connection.total_changes)

  def test_cache_read_is_not_blocked_by_writer(self):
    with tempfile.TemporaryDirectory() as directory:
      path = Path(directory) / "fixture.sqlite3"
      with TeamsCache(path) as writer:
        writer.upsert_messages("chat", "fixture", [{"id": "latest"}])
        writer.connection.execute("BEGIN IMMEDIATE")
        ready = threading.Event()
        result = []

        def read():
          with TeamsCache(path) as reader:
            result.extend(reader.list_messages("chat", "fixture", limit=50))
            ready.set()

        worker = threading.Thread(target=read)
        worker.start()
        try:
          self.assertTrue(ready.wait(2), "Cache read waited for a write lock")
        finally:
          writer.connection.rollback()
          worker.join(6)
        self.assertEqual([{"id": "latest"}], result)

  def test_one_page_arrives_before_cache_write(self):
    shown = []
    rows = [{"id": "latest"}]
    with (mock.patch.object(backend, "mock_enabled", return_value=False),
          mock.patch.object(backend, "ensure_graph_token", return_value="fixture-token"),
          mock.patch.object(backend, "graph_json", return_value={"value": rows}),
          mock.patch.object(backend, "TeamsCache") as cache):
      def open_cache():
        self.assertEqual([rows], shown, "Latest messages waited for the cache")
        return mock.Mock()

      cache.return_value.__enter__.side_effect = open_cache
      result, _ = backend.execute(
          ["teams", "chat", "message", "list", "--chatId", "fixture", "--limit", "50"],
          progress=shown.append)
      self.assertEqual(rows, result)

  def test_live_request_reports_only_numeric_stage_timings(self):
    timings = {}
    context = backend.REQUEST_TIMINGS.set(timings)
    try:
      with (mock.patch.object(backend, "mock_enabled", return_value=False),
            mock.patch.object(backend, "ensure_graph_token", return_value="fixture-token"),
            mock.patch.object(backend.urllib.request, "urlopen", return_value=io.BytesIO(b'{"value":[]}')),
            mock.patch.object(backend.GRAPH_REQUEST_BUDGET, "acquire"),
            mock.patch.object(backend, "TeamsCache")):
        backend.execute(["teams", "chat", "message", "list", "--chatId", "private-fixture", "--limit", "50"])
      self.assertEqual({"authMs", "httpMs", "httpCalls", "throttleMs", "cacheMs"}, set(timings))
      self.assertEqual(1, timings["httpCalls"])
      self.assertTrue(all(isinstance(value, (int, float)) and value >= 0 for value in timings.values()))
    finally:
      backend.REQUEST_TIMINGS.reset(context)
