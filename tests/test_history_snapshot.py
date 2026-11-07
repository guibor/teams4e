"""Bounded status exports stop actual pagination; no Teams account is used."""

import os
import sys
import tempfile
import unittest
import urllib.parse
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin"))
import teams4e_graph as backend
from teams4e_history import bounded_history
from teams4e_mock import MockTenant


def row(index, when):
  return {"id": str(index), "createdDateTime": when,
          "body": {"contentType": "text", "content": "Synthetic message"}}


class SnapshotTests(unittest.TestCase):
  def test_18000_message_chat_stops_after_five_pages_at_month_boundary(self):
    now = datetime(2026, 11, 7, 12, tzinfo=timezone.utc)
    messages = [row(i, (now - timedelta(hours=i * 3)).isoformat()) for i in range(18000)]
    pages = [{"value": messages[i:i + 50], "@odata.nextLink": f"/page/{i + 50}"}
             for i in range(0, len(messages), 50)]
    with mock.patch.object(backend, "graph_json", side_effect=pages) as request:
      result = backend.export_message_snapshot("fixture", "token",
                                               since="2026-10-08T12:00:00Z", limit=5000)
    self.assertEqual(5, request.call_count)
    self.assertEqual(241, result["history"]["messageCount"])
    self.assertEqual("date", result["history"]["stopReason"])
    self.assertFalse(result["history"]["complete"])
    query = urllib.parse.parse_qs(urllib.parse.urlparse(request.call_args_list[0].args[0]).query)
    self.assertEqual(["createdDateTime desc"], query["$orderby"])
    self.assertNotIn("$filter", query)  # createdDateTime gt is not supported.

  def test_message_cap_stops_before_next_page_and_keeps_newest(self):
    pages = [{"value": [row(i, "2026-11-07T12:00:00Z") for i in range(start, start + 50)],
              "@odata.nextLink": f"/page/{start + 50}"} for start in (0, 50, 100)]
    with mock.patch.object(backend, "graph_json", side_effect=pages) as request:
      result = backend.export_message_snapshot("fixture", "token", limit=75)
    self.assertEqual(2, request.call_count)
    self.assertEqual([str(i) for i in range(75)], [message["id"] for message in result["value"]])
    self.assertEqual("messageLimit", result["history"]["stopReason"])

  def test_cap_at_page_edge_does_not_fetch_one_more_page(self):
    with mock.patch.object(backend, "graph_json", return_value={
        "value": [row(i, "2026-11-07T12:00:00Z") for i in range(50)],
        "@odata.nextLink": "/older",
    }) as request:
      result = backend.export_message_snapshot("fixture", "token", limit=50)
    self.assertEqual(1, request.call_count)
    self.assertEqual("messageLimit", result["history"]["stopReason"])

  def test_cutoff_is_inclusive_normalizes_offsets_and_ignores_edit_date(self):
    old = row("old", "2026-10-08T11:59:59Z")
    old["lastModifiedDateTime"] = "2026-11-07T12:00:00Z"
    result = bounded_history([{"value": [row("edge", "2026-10-08T15:00:00+03:00"), old]}],
                             since="2026-10-08T12:00:00Z")
    self.assertEqual(["edge"], [message["id"] for message in result["value"]])
    self.assertEqual("date", result["history"]["stopReason"])

  def test_empty_window_does_not_fetch_old_history(self):
    with mock.patch.object(backend, "graph_json", return_value={
        "value": [row("old", "2020-01-01T00:00:00Z")], "@odata.nextLink": "/older",
    }) as request:
      result = backend.export_message_snapshot("fixture", "token", since="2026-10-08T12:00:00Z")
    self.assertEqual(1, request.call_count)
    self.assertEqual([], result["value"])
    self.assertTrue(result["history"]["bounded"])

  def test_undated_rows_are_retained_counted_and_bounded(self):
    result = bounded_history([{"value": [row(1, None), row(2, "bad"), row(3, "2026-11-07T12:00:00Z")]}],
                             since="2026-10-08T12:00:00Z", limit=2)
    self.assertEqual(2, result["history"]["undatedMessageCount"])
    self.assertEqual("messageLimit", result["history"]["stopReason"])

  def test_empty_and_exhausted_snapshots_are_not_full_history_claims(self):
    for rows in ([], [row(1, "2026-11-07T12:00:00Z")]):
      result = bounded_history([{"value": rows}], limit=1)
      self.assertEqual("exhausted", result["history"]["stopReason"])
      self.assertFalse(result["history"]["complete"])

  def test_bad_bounds_are_rejected_before_network_requests(self):
    for kwargs in ({}, {"since": "invalid"}, {"since": "2026-10-01"},
                   {"limit": 0}, {"limit": -2}, {"limit": True}):
      with self.subTest(kwargs=kwargs), mock.patch.object(backend, "graph_json") as request:
        with self.assertRaises(backend.BackendError):
          backend.export_message_snapshot("fixture", "token", **kwargs)
        request.assert_not_called()

  def test_repeated_pages_and_network_errors_are_failures_not_partial_success(self):
    with mock.patch.object(backend, "graph_json", return_value={
        "value": [], "@odata.nextLink": "/repeat",
    }):
      with self.assertRaisesRegex(backend.BackendError, "repeated"):
        backend.export_message_snapshot("fixture", "token", limit=100)
    with mock.patch.object(backend, "graph_json", side_effect=[
        {"value": [row(1, "2026-11-07T12:00:00Z")], "@odata.nextLink": "/older"},
        backend.BackendError("temporary failure"),
    ]):
      with self.assertRaises(backend.BackendError):
        backend.export_message_snapshot("fixture", "token", limit=100)

  def test_cli_dispatch_and_mock_share_bounded_contract(self):
    args = ["teams", "chat", "message", "snapshot", "--chatId", "fixture",
            "--since", "2026-10-08T12:00:00Z", "--limit", "2"]
    rows = [row(i, f"2026-11-0{7 - i}T12:00:00Z") for i in range(4)]
    with (mock.patch.object(backend, "mock_enabled", return_value=False),
          mock.patch.object(backend, "ensure_graph_token", return_value="fixture-token"),
          mock.patch.object(backend, "graph_json", return_value={"value": rows}),
          mock.patch.object(backend, "TeamsCache")):
      live, _ = backend.execute(args)
    with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {
        "TEAMS4E_MOCK_STATE": str(Path(directory) / "mock.json"),
    }):
      tenant = MockTenant()
      tenant.state["chatMessages"]["fixture"] = list(reversed(rows))
      synthetic = tenant.execute(args)
    self.assertEqual(live, synthetic)


if __name__ == "__main__":
  unittest.main()
