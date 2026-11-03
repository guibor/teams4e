"""Thread-loading latency regressions without a company account."""

import io
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
