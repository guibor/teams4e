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

    def test_chat_by_id_is_one_exact_request_not_participant_search(self):
        with mock.patch.object(backend, "mock_enabled", return_value=False), \
             mock.patch.object(backend, "ensure_graph_token", return_value="token"), \
             mock.patch.object(backend, "graph_json", return_value={"id": "chat"}) as get, \
             mock.patch.object(backend, "find_chat_by_participants") as scan:
            result = backend.execute(["teams", "chat", "get", "--chatId", "19:meeting_AbCd@thread.v2"])
        self.assertEqual(({"id": "chat"}, "json"), result)
        get.assert_called_once_with("/chats/19%3Ameeting_AbCd%40thread.v2", "token")
        scan.assert_not_called()

    def test_reschedule_updates_only_one_occurrence_time(self):
        event = {"id": "occ/1", "type": "occurrence", "seriesMasterId": "series",
                 "isOrganizer": True, "attendees": [{"emailAddress": {"address": "a@example.test"}}]}
        with mock.patch.object(backend, "get_calendar_event", return_value=event), \
             mock.patch.object(backend, "graph_json", return_value={**event, "subject": "Moved"}) as update:
            result = backend.reschedule_calendar_event(
                "occ/1", "2026-10-04T12:00:00+03:00", "2026-10-04T13:00:00+03:00", "token")
        self.assertEqual("rescheduled", result["status"])
        self.assertEqual("/me/events/occ%2F1", update.call_args.args[0])
        self.assertEqual("PATCH", update.call_args.kwargs["method"])
        self.assertEqual({"start", "end"}, set(update.call_args.kwargs["payload"]))
        self.assertEqual("2026-10-04T09:00:00", update.call_args.kwargs["payload"]["start"]["dateTime"])

    def test_reschedule_rejects_attendees_cancelled_all_day_and_series(self):
        for event in ({}, {"isOrganizer": False}, {"isOrganizer": True, "isCancelled": True},
                      {"isOrganizer": True, "isAllDay": True},
                      {"isOrganizer": True, "type": "seriesMaster"}):
            with self.subTest(event=event), \
                 mock.patch.object(backend, "get_calendar_event", return_value=event), \
                 mock.patch.object(backend, "graph_json") as update:
                with self.assertRaises(backend.BackendError):
                    backend.reschedule_calendar_event(
                        "event", "2026-10-04T12:00:00Z", "2026-10-04T13:00:00Z", "token")
                update.assert_not_called()

    def test_reschedule_rejects_invalid_dates_before_patch(self):
        with mock.patch.object(backend, "get_calendar_event", return_value={"isOrganizer": True}), \
             mock.patch.object(backend, "graph_json") as update:
            for start, end in (("2026-10-04T12:00:00", "2026-10-04T13:00:00"),
                               ("2026-10-04T12:00:00Z", "2026-10-04T11:00:00Z")):
                with self.assertRaises(backend.BackendError):
                    backend.reschedule_calendar_event("event", start, end, "token")
            update.assert_not_called()

    def test_reschedule_cli_routes_explicit_action(self):
        with mock.patch.object(backend, "mock_enabled", return_value=False), \
             mock.patch.object(backend, "ensure_graph_token", return_value="token"), \
             mock.patch.object(backend, "reschedule_calendar_event", return_value={}) as move:
            backend.execute(["teams", "calendar", "event", "reschedule",
                             "--eventId", "event", "--start", "from", "--end", "until"])
        move.assert_called_once_with("event", "from", "until", "token")

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
                chat = tenant.state["chats"][0]
                self.assertEqual(chat, tenant.execute(["teams", "chat", "get", "--chatId", chat["id"]]))
                with self.assertRaises(ValueError):
                    tenant.execute(args + ["--calendarId", "unknown"])
                moved = tenant.execute(["teams", "calendar", "event", "reschedule",
                                        "--eventId", "mock-calendar-0",
                                        "--start", "2026-10-04T11:00:00Z",
                                        "--end", "2026-10-04T12:00:00Z"])
                self.assertEqual("rescheduled", moved["status"])
                persisted = MockTenant().execute(["teams", "calendar", "event", "get",
                                                  "--eventId", "mock-calendar-0"])
                self.assertEqual(moved["event"]["start"], persisted["start"])



if __name__ == "__main__":
    unittest.main()
