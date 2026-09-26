"""Calendar-first loading and process-wide Outlook concurrency regressions."""
import io
import json
import sys
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin"))
import teams4e_graph as backend


class UpcomingTests(unittest.TestCase):
  def event(self, name, offset, thread="test", **extra):
    start = datetime.now(timezone.utc) + timedelta(days=offset)
    return {
        "id": name, "type": "occurrence", "seriesMasterId": "series",
        "start": {"dateTime": start.isoformat()},
        "end": {"dateTime": (start + timedelta(hours=1)).isoformat()},
        "onlineMeeting": {"joinUrl": "https://teams.microsoft.com/l/meetup-join/"
                          f"19%3ameeting_{thread}%40thread.v2/0"},
        **extra,
    }

  def test_calendar_first_matches_nearest_occurrence_without_chat_fanout(self):
    meetings = [{"chatId": "19:meeting_test@thread.v2"}] + [
        {"chatId": f"19:meeting_old{i}@thread.v2"} for i in range(300)]
    events = [self.event("later", 5), self.event("next", 1),
              self.event("past", -1), self.event("too-far", 20),
              self.event("cancelled", 0.1, isCancelled=True),
              self.event("declined", 0.2, responseStatus={"response": "declined"})]
    with mock.patch.object(backend, "iterate_calendar_view_events",
                           return_value=iter(events)) as scan, \
         mock.patch.object(backend, "get_meeting_chat_metadata_batch") as chats, \
         mock.patch.object(backend, "get_calendar_events_batch") as ids, \
         mock.patch.object(backend, "next_recurring_event") as series:
      rows = backend.list_meeting_events_batch(
          meetings, "token", upcoming_days=14, meeting_concurrency=20)
    self.assertEqual("next", rows[0]["event"]["id"])
    self.assertTrue(all(row["event"] is None for row in rows[1:]))
    self.assertTrue(all(row["eventError"] is None for row in rows))
    self.assertEqual(301, len(rows))
    self.assertEqual(14, rows[0]["upcomingWindowDays"])
    self.assertEqual(1, scan.call_count)
    args = scan.call_args.kwargs
    self.assertEqual(timedelta(days=14), args["end"] - args["start"])
    self.assertEqual(100, args["page_size"])
    chats.assert_not_called()
    ids.assert_not_called()
    series.assert_not_called()

  def test_join_url_fallback_series_ids_and_ongoing_meetings(self):
    ongoing = self.event("ongoing", -0.01)
    fallback = self.event("fallback", 1, thread="fallback")
    fallback["onlineMeetingUrl"] = fallback.pop("onlineMeeting")["joinUrl"]
    unrelated = self.event("id-only", 2, thread="other")
    with mock.patch.object(backend, "iterate_calendar_view_events",
                           return_value=iter([ongoing, fallback, unrelated])):
      rows = backend.list_upcoming_meeting_events([
          {"chatId": "19:meeting_test@thread.v2"},
          {"chatId": "19:meeting_fallback@thread.v2"},
          {"chatId": "no-thread-key", "eventId": "id-only"},
      ], "token")
    self.assertEqual(["ongoing", "fallback", "id-only"],
                     [row["event"]["id"] for row in rows])

  def test_late_page_error_retains_partial_results_and_reports_error(self):
    def pages(*args, **kwargs):
      yield self.event("next", 1)
      raise backend.BackendError("Microsoft Graph HTTP 429: MailboxConcurrency")
    with mock.patch.object(backend, "iterate_calendar_view_events", side_effect=pages):
      rows = backend.list_upcoming_meeting_events([
          {"chatId": "19:meeting_test@thread.v2"}, {"chatId": "missing"}], "token")
    self.assertEqual("next", rows[0]["event"]["id"])
    self.assertTrue(all("429" in row["eventError"] for row in rows))

  def test_cli_keeps_legacy_batch_option_optional(self):
    with mock.patch.object(backend, "mock_enabled", return_value=False), \
         mock.patch.object(backend, "ensure_graph_token", return_value="token"), \
         mock.patch.object(backend, "list_meeting_events_batch", return_value=[]) as batch:
      args = ["teams", "meeting", "event", "batch", "--meetings", "[]"]
      backend.execute(args)
      self.assertIsNone(batch.call_args.kwargs["upcoming_days"])
      backend.execute(args + ["--upcomingDays", "14"])
      self.assertEqual(14, batch.call_args.kwargs["upcoming_days"])

  def test_no_input_does_not_fetch_and_horizon_is_bounded(self):
    with mock.patch.object(backend, "iterate_calendar_view_events",
                           return_value=iter([])) as scan:
      self.assertEqual([], backend.list_upcoming_meeting_events([], "token"))
      scan.assert_not_called()
      rows = backend.list_upcoming_meeting_events([{"chatId": "missing"}], "token", 999)
      self.assertEqual(60, rows[0]["upcomingWindowDays"])

  def test_outlook_classifier_does_not_throttle_teams_chat_requests(self):
    for path in ["/me/events/id", "/me/calendar/getSchedule",
                 "/me/findMeetingTimes", "/users/user/calendarView",
                 backend.GRAPH_ROOT + "/me/calendarView?$skip=100"]:
      self.assertTrue(backend.outlook_request(path), path)
    for path in ["/me/chats", "/chats/id/messages", "/teams/id", "/me/onlineMeetings"]:
      self.assertFalse(backend.outlook_request(path), path)
    self.assertTrue(backend.outlook_envelope("/$batch", {
        "requests": [{"url": "/me/events/id"}]}))

  def test_calendar_workers_share_one_guard_even_with_high_parallelism(self):
    state = {"active": 0, "max": 0}
    lock = threading.Lock()
    def respond(request, **kwargs):
      with lock:
        state["active"] += 1
        state["max"] = max(state["max"], state["active"])
      time.sleep(0.01)
      with lock:
        state["active"] -= 1
      return io.BytesIO(b"{}")
    with mock.patch.object(backend, "GRAPH_REQUEST_BUDGET"), \
         mock.patch.object(backend.urllib.request, "urlopen", side_effect=respond):
      with ThreadPoolExecutor(max_workers=12) as workers:
        jobs = [workers.submit(backend.graph_json, "/me/calendarView", "token")
                for _ in range(6)]
        jobs += [workers.submit(backend.graph_json, "/$batch", "token",
                                method="POST", payload={"requests": [
                                    {"url": "/me/events/a"}, {"url": "/me/events/b"}]})
                 for _ in range(6)]
        for job in jobs:
          job.result(timeout=5)
    self.assertEqual(1, state["max"])

  def test_outlook_failure_releases_guard(self):
    def respond(*args, **kwargs):
      raise backend.urllib.error.URLError("offline")
    with mock.patch.object(backend, "GRAPH_REQUEST_BUDGET"), \
         mock.patch.object(backend.urllib.request, "urlopen", side_effect=respond):
      with self.assertRaises(backend.BackendError):
        backend.graph_json("/me/events/a", "token")
    self.assertTrue(backend.OUTLOOK_REQUEST_LOCK.acquire(blocking=False))
    backend.OUTLOOK_REQUEST_LOCK.release()


if __name__ == "__main__":
  unittest.main()
