"""Offline Graph pacing and throttling tests; no tenant or real sleeping."""

import io
import json
import sys
import threading
import unittest
import urllib.error
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin"))
import teams4e_graph as backend


class Clock:
  def __init__(self):
    self.now = 0.0
    self.sleeps = []
    self.lock = threading.Lock()

  def time(self):
    with self.lock:
      return self.now

  def sleep(self, seconds):
    with self.lock:
      self.sleeps.append(seconds)
      self.now += seconds


class ThrottleTests(unittest.TestCase):
  def setUp(self):
    self.clock = Clock()
    self.budget = backend.GraphRequestBudget(
        clock=self.clock.time, sleep=self.clock.sleep)
    patcher = mock.patch.object(backend, "GRAPH_REQUEST_BUDGET", self.budget)
    patcher.start()
    self.addCleanup(patcher.stop)

  def response(self, value):
    return io.BytesIO(json.dumps(value).encode())

  def throttled(self, headers=None):
    return urllib.error.HTTPError(
        "https://graph.microsoft.com/v1.0/me", 429, "Too many requests",
        headers or {}, io.BytesIO(b'{"message":"API calls quota exceeded! 50Per10Secs"}'))

  def test_batch_items_consume_budget_individually(self):
    self.budget.acquire(20)
    self.budget.acquire(20)
    self.assertEqual([], self.clock.sleeps)
    self.budget.acquire()
    self.assertEqual([10.0], self.clock.sleeps)

  def test_weighted_reservation_waits_until_enough_old_slots_expire(self):
    self.budget.acquire(20)
    self.clock.sleep(3)
    self.budget.acquire(20)
    self.budget.acquire(30)
    self.assertEqual(13.0, self.clock.now)
    self.assertEqual(30, len(self.budget.requests))

  def test_parallel_workers_share_one_budget(self):
    with ThreadPoolExecutor(max_workers=8) as pool:
      list(pool.map(lambda _: self.budget.acquire(20), range(8)))
    self.assertGreaterEqual(self.clock.now, 30)
    self.assertLessEqual(len(self.budget.requests), 40)

  def test_cooldown_is_shared_and_never_shortened(self):
    self.budget.defer(30)
    self.budget.defer(2)
    with ThreadPoolExecutor(max_workers=1) as pool:
      pool.submit(self.budget.acquire).result()
    self.assertEqual(30, self.clock.now)

  def test_retry_after_seconds_is_not_capped(self):
    self.assertEqual(120, backend.graph_retry_delay({"rEtRy-AfTeR": "120"}, 0))

  def test_retry_after_http_date(self):
    now = datetime(2026, 9, 27, tzinfo=timezone.utc)
    with mock.patch.object(backend, "datetime") as date:
      date.now.return_value = now
      delay = backend.graph_retry_delay(
          {"Retry-After": "Sun, 27 Sep 2026 00:02:00 GMT"}, 0)
    self.assertEqual(120, delay)

  def test_missing_or_invalid_header_uses_quota_sized_exponential_backoff(self):
    for headers in ({}, {"Retry-After": "nonsense"}, {"Retry-After": "NaN"}):
      self.assertEqual(10, backend.graph_retry_delay(headers, 0, throttled=True))
      self.assertEqual(20, backend.graph_retry_delay(headers, 1, throttled=True))

  def test_json_429_waits_before_retry(self):
    with mock.patch.object(backend.urllib.request, "urlopen", side_effect=[
        self.throttled(), self.response({"id": "ok"}),
    ]) as request:
      self.assertEqual({"id": "ok"}, backend.graph_json("/me", "token"))
    self.assertEqual(2, request.call_count)
    self.assertEqual(10, self.clock.now)

  def test_text_429_uses_same_cooldown(self):
    with mock.patch.object(backend.urllib.request, "urlopen", side_effect=[
        self.throttled({"Retry-After": "12"}), io.BytesIO(b"WEBVTT"),
    ]):
      self.assertEqual("WEBVTT", backend.graph_text("/me", "token"))
    self.assertEqual(12, self.clock.now)

  def test_failed_final_attempt_still_slows_other_workers(self):
    with mock.patch.object(backend.urllib.request, "urlopen",
                           side_effect=[self.throttled() for _ in range(4)]) as request:
      with self.assertRaisesRegex(backend.BackendError, "HTTP 429"):
        backend.graph_json("/me", "token")
    self.assertEqual(backend.GRAPH_RETRY_ATTEMPTS, request.call_count)
    before = self.clock.now
    self.budget.acquire()
    self.assertGreaterEqual(self.clock.now - before, 60)

  def test_json_batch_transport_reserves_all_items(self):
    with mock.patch.object(backend.urllib.request, "urlopen",
                           return_value=self.response({"responses": []})):
      backend.graph_json("/$batch", "token", method="POST",
                         payload={"requests": [{"id": str(i)} for i in range(20)]})
    self.assertEqual(20, len(self.budget.requests))

  def test_batch_retries_only_throttled_items_after_longest_delay(self):
    requests = []
    def batch(_path, _token, **kwargs):
      items = kwargs["payload"]["requests"]
      self.budget.acquire(len(items))
      requests.append([item["id"] for item in items])
      if len(requests) == 1:
        return {"responses": [
            {"id": "0", "status": 200, "body": {"id": "success"}},
            {"id": "1", "status": 429, "headers": {"Retry-After": "12"}, "body": {}},
            {"id": "2", "status": 429, "headers": {"retry-after": "15"}, "body": {}},
            {"id": "3", "status": 403, "body": {"error": {"message": "denied"}}},
        ]}
      self.assertGreaterEqual(self.clock.now, 15)
      return {"responses": [
          {"id": item["id"], "status": 200, "body": {"id": "recovered"}}
          for item in items
      ]}
    with mock.patch.object(backend, "graph_json", side_effect=batch):
      rows = backend.graph_get_json_batch([(str(i), "/me") for i in range(4)], "token")
    self.assertEqual([["0", "1", "2", "3"], ["1", "2"]], requests)
    self.assertEqual("success", rows["0"][0]["id"])
    self.assertEqual("recovered", rows["1"][0]["id"])
    self.assertEqual("recovered", rows["2"][0]["id"])
    self.assertIn("HTTP 403", rows["3"][1])

  def test_batch_429_exhaustion_is_bounded(self):
    with mock.patch.object(backend, "graph_json", return_value={"responses": [
        {"id": "0", "status": 429,
         "body": {"message": "API calls quota exceeded! 50Per10Secs"}},
    ]}) as request:
      rows = backend.graph_get_json_batch([("one", "/me")], "token")
    self.assertEqual(backend.GRAPH_RETRY_ATTEMPTS, request.call_count)
    self.assertIn("50Per10Secs", rows["one"][1])

  def test_validation_precedes_budget_and_network(self):
    with mock.patch.object(backend.urllib.request, "urlopen") as request:
      with self.assertRaisesRegex(backend.BackendError, "non-Graph"):
        backend.graph_json("https://example.com/token-sink", "token")
    request.assert_not_called()
    self.assertFalse(self.budget.requests)


if __name__ == "__main__":
  unittest.main()
