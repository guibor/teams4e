"""Deterministic transcript cancellation tests; no Graph calls or credentials."""

import contextlib
import io
import json
import sys
import threading
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin"))
import teams4e_graph as backend


class ReadCancellationTests(unittest.TestCase):
  def test_cancel_between_pages_skips_remaining_history(self):
    event = threading.Event()
    context = backend.READ_CANCEL.set(event)
    try:
      with mock.patch.object(backend, "graph_json", return_value={
          "value": [{"id": "latest"}], "@odata.nextLink": "/older",
      }) as get:
        with self.assertRaises(backend.ReadCancelled):
          backend.list_messages("fixture", "token", limit=100,
                                first_page=lambda _: event.set())
        self.assertEqual(1, get.call_count)
    finally:
      backend.READ_CANCEL.reset(context)

  def test_cancel_while_http_is_running_discards_response(self):
    event = threading.Event()
    context = backend.READ_CANCEL.set(event)
    try:
      def response(*args, **kwargs):
        event.set()
        return {"value": [{"id": "stale"}]}

      with mock.patch.object(backend, "graph_json", side_effect=response):
        with self.assertRaises(backend.ReadCancelled):
          backend.list_messages("fixture", "token", limit=100)
    finally:
      backend.READ_CANCEL.reset(context)

  def test_cancel_interrupts_budget_wait_without_resetting_budget(self):
    event = threading.Event()
    context = backend.READ_CANCEL.set(event)
    budget = backend.GraphRequestBudget(limit=1, window=60)
    try:
      budget.acquire()
      event.set()
      with self.assertRaises(backend.ReadCancelled):
        budget.acquire()
      with self.assertRaises(backend.ReadCancelled):
        backend.read_wait(60)
      self.assertEqual(1, len(budget.requests))
    finally:
      backend.READ_CANCEL.reset(context)

  def test_server_cancels_reads_but_never_mutations(self):
    started = threading.Event()
    finished = threading.Event()
    observed = []

    def execute(args, **kwargs):
      if args[-1] == "old":
        started.set()
        try:
          backend.read_wait(2)
        finally:
          finished.set()
        self.fail("Cancelled read was allowed to finish")
      observed.append((args[-1], backend.READ_CANCEL.get()))
      return [], "json"

    def requests():
      yield json.dumps({"id": 1, "args": ["teams", "chat", "message", "list", "old"]})
      self.assertTrue(started.wait(2))
      yield '{"cancel":1}'
      self.assertTrue(finished.wait(2))
      yield json.dumps({"id": 2, "args": ["teams", "chat", "message", "send"]})
      yield '{"cancel":2}'
      yield json.dumps({"id": 3, "args": ["teams", "chat", "message", "list", "new"]})

    output = io.StringIO()
    with (mock.patch.object(backend.sys, "stdin", requests()),
          mock.patch.object(backend, "execute", side_effect=execute),
          contextlib.redirect_stdout(output)):
      backend.serve()
    rows = [json.loads(line) for line in output.getvalue().splitlines()]
    self.assertEqual({2, 3}, {row["id"] for row in rows})
    self.assertTrue(all(row["ok"] for row in rows))
    self.assertIsNone(dict(observed)["send"])
    self.assertIsNotNone(dict(observed)["new"])

  def test_cache_responds_while_all_network_workers_are_occupied(self):
    lock = threading.Lock()
    blocked = threading.Event()
    cached = threading.Event()
    count = 0

    def execute(args, **kwargs):
      nonlocal count
      if args[:2] == ["teams", "cache"]:
        cached.set()
        return [], "json"
      with lock:
        count += 1
        if count == 8:
          blocked.set()
      self.assertTrue(cached.wait(3), "Cache queued behind live requests")
      return [], "json"

    def requests():
      for i in range(8):
        args = (["status"] if i < 6 else
                ["teams", "chat", "message", "list", "--limit", "50"])
        yield json.dumps({"id": i, "args": args})
      self.assertTrue(blocked.wait(3))
      yield json.dumps({"id": 9, "args": ["teams", "cache", "chat", "message", "list"]})

    output = io.StringIO()
    with (mock.patch.object(backend.sys, "stdin", requests()),
          mock.patch.object(backend, "execute", side_effect=execute),
          contextlib.redirect_stdout(output)):
      backend.serve()
    rows = [json.loads(line) for line in output.getvalue().splitlines()]
    self.assertEqual(9, len(rows))
    self.assertTrue(all(row["ok"] for row in rows))
