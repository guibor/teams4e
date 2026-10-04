"""Independent calendar view API and mock regressions."""
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin"))
import teams4e_graph as backend
from teams4e_mock import MockTenant


class CalendarTests(unittest.TestCase):
    def test_view_retains_non_meetings_and_each_recurrence(self):
        events = [
            {"id": "appointment", "subject": "Dentist"},
            {"id": "occurrence-1", "seriesMasterId": "same-series"},
            {"id": "occurrence-2", "seriesMasterId": "same-series"},
            {"id": "all-day", "isAllDay": True},
            {"id": "cancelled", "isCancelled": True},
        ]
        with mock.patch.object(backend, "iterate_calendar_view_events",
                               return_value=iter(events)) as scan:
            result = backend.list_calendar_view(
                "2026-10-01T00:00:00+03:00", "2026-11-01T00:00:00+02:00", "token")
        self.assertTrue(result["complete"])
        self.assertEqual(5, len(result["events"]))
        self.assertEqual(1, scan.call_count)
        self.assertEqual(100, scan.call_args.kwargs["page_size"])
        self.assertEqual("2026-09-30T21:00:00+00:00", result["start"])

    def test_range_rejects_unbounded_invalid_and_naive_requests(self):
        for first, last in [
            ("bad", "bad"), ("2026-01-01", "2026-01-03"),
            ("2026-01-02T00:00:00Z", "2026-01-01T00:00:00Z"),
            ("2026-01-01T00:00:00Z", "2027-01-01T00:00:00Z"),
        ]:
            with self.assertRaises(backend.BackendError):
                backend.calendar_range(first, last)

    def test_partial_pages_are_not_silent_empty_success(self):
        def pages(*args, **kwargs):
            yield {"id": "one"}
            raise backend.BackendError("HTTP 429: Retry later")
        with mock.patch.object(backend, "iterate_calendar_view_events", side_effect=pages):
            result = backend.list_calendar_view(
                "2026-10-01T00:00:00Z", "2026-10-08T00:00:00Z", "token")
        self.assertFalse(result["complete"])
        self.assertEqual([{"id": "one"}], result["events"])
        self.assertIn("429", result["error"])

    def test_named_calendar_pagination_and_no_chat_fanout(self):
        with mock.patch.object(backend, "graph_json", side_effect=[
            {"value": [{"id": "one"}], "@odata.nextLink": "/me/calendars/abc/calendarView?$skip=100"},
            {"value": [{"id": "two"}]},
        ]) as get:
            result = backend.list_calendar_view(
                "2026-10-01T00:00:00Z", "2026-10-08T00:00:00Z", "token", "abc/def")
        url = get.call_args_list[0].args[0]
        self.assertIn("/me/calendars/abc%2Fdef/calendarView?", url)
        self.assertEqual(["100"], parse_qs(urlparse(url).query)["$top"])
        self.assertEqual(2, get.call_count)
        self.assertEqual(2, len(result["events"]))

    def test_duplicate_page_entries_deduplicate_by_event_not_series(self):
        with mock.patch.object(backend, "iterate_calendar_view_events",
                               return_value=iter([{"id": "one"}, {"id": "one", "subject": "updated"}])):
            result = backend.list_calendar_view(
                "2026-10-01T00:00:00Z", "2026-10-08T00:00:00Z", "token")
        self.assertEqual([{"id": "one", "subject": "updated"}], result["events"])

    def test_cli_routes_with_existing_token(self):
        with mock.patch.object(backend, "mock_enabled", return_value=False), \
             mock.patch.object(backend, "ensure_graph_token", return_value="token"), \
             mock.patch.object(backend, "list_calendar_view", return_value={}) as view:
            backend.execute(["teams", "calendar", "view", "--start", "from",
                             "--end", "until", "--calendarId", "other"])
        view.assert_called_once_with("from", "until", "token", calendar_id="other")

    def test_mock_has_independent_events_and_calendar_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.dict("os.environ", {"TEAMS4E_MOCK_STATE": str(Path(directory) / "mock.json")}):
                tenant = MockTenant()
                now = datetime.now(timezone.utc)
                args = ["teams", "calendar", "view", "--start", (now - timedelta(days=1)).isoformat(),
                        "--end", (now + timedelta(days=14)).isoformat()]
                view = tenant.execute(args)
                rows = [event for event in view["events"] if event["id"].startswith("mock-calendar-")]
                self.assertEqual(6, len(rows))
                self.assertTrue(any(event["isAllDay"] for event in rows))
                self.assertTrue(all("body" not in event for event in rows))
                detail = tenant.execute(["teams", "calendar", "event", "get", "--eventId", rows[0]["id"]])
                self.assertIn("body", detail)
                self.assertTrue(tenant.execute(["teams", "calendar", "list"]))
                with self.assertRaises(ValueError):
                    tenant.execute(args + ["--calendarId", "unknown"])


if __name__ == "__main__":
    unittest.main()
