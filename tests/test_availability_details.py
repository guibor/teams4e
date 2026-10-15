"""Own calendar enrichment is bounded, read-only, and conservative offline."""
import copy
import sys
import unittest
from pathlib import Path
from unittest import mock
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin"))
import teams4e_graph as backend


class CalendarDetailsTests(unittest.TestCase):
  def setUp(self):
    self.people = [{"email": "self@example.test", "isSelf": True},
                   {"email": "other@example.test"}]
    self.event = {"id": "occurrence", "subject": "Design review", "showAs": "busy",
                  "start": {"dateTime": "2026-10-14T09:00:00", "timeZone": "UTC"},
                  "end": {"dateTime": "2026-10-14T10:00:00", "timeZone": "UTC"},
                  "location": {"displayName": "Room A"}}

  def enrich(self, schedules):
    backend.enrich_own_schedule(schedules, self.people,
                               "2026-10-14T00:00:00Z", "2026-10-16T00:00:00Z", "token")

  def test_own_occurrences_restore_details_and_preserve_shared_data(self):
    schedules = [{"scheduleId": "SELF@example.test", "error": {"message": "denied"}},
                 {"scheduleId": "other@example.test", "scheduleItems": [{"subject": "Shared"}]}]
    original_other = copy.deepcopy(schedules[1])
    private = {**self.event, "id": "private", "sensitivity": "private"}
    with mock.patch.object(backend, "graph_json", return_value={
        "value": [self.event, private, {**self.event, "isCancelled": True}]
    }) as request:
      self.enrich(schedules)
    self.assertEqual(1, request.call_count)
    self.assertNotIn("method", request.call_args.kwargs)
    url = urlsplit(request.call_args.args[0])
    self.assertEqual("/me/calendarView", url.path)
    self.assertEqual(["2026-10-14T00:00:00Z"], parse_qs(url.query)["startDateTime"])
    self.assertNotIn("error", schedules[0])
    self.assertTrue(schedules[0]["detailsComplete"])
    self.assertEqual(2, len(schedules[0]["scheduleItems"]))
    self.assertEqual("Design review", schedules[0]["scheduleItems"][0]["subject"])
    self.assertEqual("Room A", schedules[0]["scheduleItems"][0]["location"]["displayName"])
    self.assertTrue(schedules[0]["scheduleItems"][1]["isPrivate"])
    self.assertEqual(original_other, schedules[1])

  def test_denied_details_keep_successful_free_busy(self):
    schedules = [{"scheduleId": "self@example.test", "availabilityView": "0022"}]
    with mock.patch.object(backend, "graph_json", side_effect=backend.BackendError("403")):
      self.enrich(schedules)
    self.assertEqual("0022", schedules[0]["availabilityView"])
    self.assertEqual("403", schedules[0]["detailsError"])
    self.assertNotIn("scheduleItems", schedules[0])

  def test_incomplete_details_cannot_turn_unknown_into_free(self):
    schedules = []
    with mock.patch.object(backend, "graph_collection_with_metadata",
                           return_value=([self.event], 10, False)) as request:
      self.enrich(schedules)
    self.assertEqual(1000, request.call_args.kwargs["limit"])
    self.assertIn("error", schedules[0])
    self.assertNotIn("scheduleItems", schedules[0])
    self.assertIn("truncated", schedules[0]["detailsError"])
    self.assertFalse(schedules[0]["detailsComplete"])

  def test_empty_complete_calendar_is_distinct_from_denied(self):
    schedules = []
    with mock.patch.object(backend, "graph_json", return_value={"value": []}):
      self.enrich(schedules)
    self.assertEqual([], schedules[0]["scheduleItems"])
    self.assertNotIn("error", schedules[0])

  def test_details_follow_pagination_without_per_event_fetches(self):
    schedules = []
    with mock.patch.object(backend, "graph_json", side_effect=[
        {"value": [self.event], "@odata.nextLink": "https://graph.microsoft.com/v1.0/next"},
        {"value": [{**self.event, "id": "next"}]},
    ]) as request:
      self.enrich(schedules)
    self.assertEqual(2, request.call_count)
    self.assertEqual(2, len(schedules[0]["scheduleItems"]))

  def test_no_self_identity_does_not_query_someone_elses_calendar(self):
    self.people = [{"email": "other@example.test"}]
    with mock.patch.object(backend, "graph_json") as request:
      self.enrich([])
    request.assert_not_called()
