"""Offline regressions for explicit calendar creation."""
import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin"))
import teams4e_graph as backend
from teams4e_calendar import calendar_draft_payload
from teams4e_mock import MockTenant


def draft():
    return {
        "subject": "Synthetic planning",
        "start": "2026-10-06T10:00:00+03:00",
        "end": "2026-10-06T10:30:00+03:00",
        "required": ["one@example.test"],
        "optional": ["ONE@example.test", "two@example.test"],
        "online": True,
        "location": "Demo room",
        "body": "<p><b>Agenda</b></p>",
        "transactionId": "88f06b7f-f43e-42e8-8e98-a4fdc7ca0b34",
    }


class CalendarCreateTests(unittest.TestCase):
    def test_explicit_create_targets_selected_calendar_and_normalizes_dates(self):
        with mock.patch.object(backend, "graph_json", return_value={"id": "created"}) as post:
            result = backend.create_calendar_event(draft(), "token", "cal/id")
        self.assertEqual("created", result["status"])
        self.assertEqual("/me/calendars/cal%2Fid/events", post.call_args.args[0])
        self.assertEqual("POST", post.call_args.kwargs["method"])
        payload = post.call_args.kwargs["payload"]
        self.assertEqual("2026-10-06T07:00:00", payload["start"]["dateTime"])
        self.assertEqual("teamsForBusiness", payload["onlineMeetingProvider"])
        self.assertEqual(["required", "optional"], [a["type"] for a in payload["attendees"]])
        self.assertEqual(draft()["transactionId"], payload["transactionId"])
        self.assertEqual("<p><b>Agenda</b></p>", payload["body"]["content"])

    def test_non_online_appointment_needs_no_attendees_or_online_permission(self):
        data = {**draft(), "online": False, "required": [], "optional": []}
        with mock.patch.object(backend, "graph_json", return_value={"id": "created"}) as post:
            backend.create_calendar_event(data, "token")
        self.assertEqual("/me/calendar/events", post.call_args.args[0])
        self.assertNotIn("onlineMeetingProvider", post.call_args.kwargs["payload"])

    def test_bad_drafts_never_reach_graph(self):
        bad = [None, [], {}, {**draft(), "subject": ""},
               {**draft(), "start": "2026-10-06T10:00:00"},
               {**draft(), "end": "2026-10-06T07:00:00Z"},
               {**draft(), "end": "2026-10-20T07:00:00Z"},
               {**draft(), "transactionId": "not-a-uuid"},
               {**draft(), "online": "yes"},
               {**draft(), "required": ["not-an-address"]},
               {**draft(), "required": "one@example.test"},
               {**draft(), "showAs": "follow"},
               {**draft(), "recurrence": {}},
               {**draft(), "isAllDay": True},
               {**draft(), "body": {}}]
        with mock.patch.object(backend, "graph_json") as post:
            for item in bad:
                with self.subTest(item=item), self.assertRaises(backend.BackendError):
                    backend.create_calendar_event(item, "token")
            post.assert_not_called()

    def test_validation_does_not_modify_the_editable_source(self):
        data = draft()
        before = copy.deepcopy(data)
        calendar_draft_payload(data)
        self.assertEqual(before, data)

    def test_cli_creation_is_explicit_and_uses_existing_token(self):
        with mock.patch.object(backend, "mock_enabled", return_value=False), \
             mock.patch.object(backend, "ensure_graph_token", return_value="token"), \
             mock.patch.object(backend, "create_calendar_event", return_value={}) as create:
            backend.execute(["teams", "calendar", "event", "create", "--draft",
                             json.dumps(draft()), "--calendarId", "chosen"])
        create.assert_called_once_with(draft(), "token", calendar_id="chosen")

    def test_mock_create_persists_and_identical_retries_do_not_duplicate(self):
        with tempfile.TemporaryDirectory() as directory, \
             mock.patch.dict("os.environ", {"TEAMS4E_MOCK_STATE": str(Path(directory) / "mock.json")}):
            tenant = MockTenant()
            initial = len(tenant.state["calendarEvents"])
            args = ["teams", "calendar", "event", "create", "--draft", json.dumps(draft())]
            created = tenant.execute(args)["event"]
            again = MockTenant().execute(args)["event"]
            self.assertEqual(created["id"], again["id"])
            self.assertEqual(initial + 1, len(MockTenant().state["calendarEvents"]))
            self.assertEqual("organizer", created["responseStatus"]["response"])
            self.assertIn("onlineMeeting", created)
            read = MockTenant().execute(["teams", "calendar", "event", "get", "--eventId", created["id"]])
            self.assertEqual(created["body"], read["body"])


if __name__ == "__main__":
    unittest.main()
