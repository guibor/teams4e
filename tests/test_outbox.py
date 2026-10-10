"""Scheduled sending uses only fixtures; never sends a real Teams message."""
import io
import json
import os
import sys
import tempfile
import threading
import unittest
import urllib.error
from datetime import datetime
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin"))
import teams4e_graph as graph
from teams4e_outbox import Outbox, RetryLater, Rejected, schedule_time


def stamp(value):
    return datetime.fromisoformat(value).timestamp()


class ScheduleTimeTests(unittest.TestCase):
    def next(self, now, **extra):
        spec = dict(mode="next", zone="UTC", days=[1, 2, 3, 4, 5], start="07:00")
        spec.update(extra)
        return schedule_time(spec, stamp(now))

    def test_never_today_even_before_seven(self):
        for hour in (0, 6, 7, 23):
            got = self.next(f"2026-10-05T{hour:02}:00:00+00:00")
            self.assertEqual(stamp("2026-10-06T07:00:00+00:00"), got["sendAt"])

    def test_weekend_and_sunday_thursday(self):
        self.assertEqual(stamp("2026-10-12T07:00:00+00:00"), self.next("2026-10-09T10:00:00+00:00")["sendAt"])
        for date in (8, 9, 10):
            got = self.next(f"2026-10-{date:02}T10:00:00+00:00", days=[0, 1, 2, 3, 4])
            self.assertEqual(stamp("2026-10-11T07:00:00+00:00"), got["sendAt"])

    def test_year_boundary_leap_day_single_workday_and_custom_hour(self):
        self.assertEqual(stamp("2027-01-01T08:45:00+00:00"), self.next("2026-12-31T23:59:00+00:00", start="08:45")["sendAt"])
        self.assertEqual(stamp("2028-02-29T07:00:00+00:00"), self.next("2028-02-28T12:00:00+00:00")["sendAt"])
        self.assertEqual(stamp("2026-10-12T07:00:00+00:00"), self.next("2026-10-05T05:00:00+00:00", days=[1])["sendAt"])

    def test_dst_and_sender_zone_not_utc_day(self):
        cases = [("2026-03-06T13:00:00+00:00", "2026-03-09T11:00:00+00:00"),
                 ("2026-10-30T13:00:00+00:00", "2026-11-02T12:00:00+00:00")]
        for before, after in cases:
            self.assertEqual(stamp(after), self.next(before, zone="America/New_York")["sendAt"])
        # UTC Monday but still Sunday in Los Angeles: next workday is Monday.
        self.assertEqual(stamp("2026-10-05T14:00:00+00:00"),
                         self.next("2026-10-05T01:00:00+00:00", zone="America/Los_Angeles")["sendAt"])

    def test_gap_advances_repeated_hour_uses_first(self):
        self.assertEqual(stamp("2026-03-08T07:00:00+00:00"), self.next(
            "2026-03-07T12:00:00+00:00", days=[0], start="02:30", zone="America/New_York")["sendAt"])
        self.assertEqual(stamp("2026-11-01T05:30:00+00:00"), self.next(
            "2026-10-31T12:00:00+00:00", days=[0], start="01:30", zone="America/New_York")["sendAt"])

    def test_explicit_dst_requires_offset_and_future(self):
        for value in ("2026-03-08 02:30", "2026-11-01 01:30", "bad", "2026-10-12", "2025-01-01 07:00"):
            with self.assertRaises(ValueError):
                schedule_time(dict(mode="explicit", zone="America/New_York", value=value), stamp("2026-01-01T00:00:00+00:00"))
        result = schedule_time(dict(mode="explicit", zone="America/New_York", value="2026-11-01T01:30:00-05:00"), 0)
        self.assertEqual(stamp("2026-11-01T06:30:00+00:00"), result["sendAt"])

    def test_invalid_configuration(self):
        for options in (dict(days=[]), dict(days=[7]), dict(days=[True]), dict(start="25:00"), dict(zone="Not/AZone")):
            with self.assertRaises((ValueError, KeyError)):
                self.next("2026-10-05T00:00:00+00:00", **options)


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "outbox.sqlite3"
        self.id = "fixture-message-0001"
        self.record = dict(sendAt=1000, displayTime="fixture time", zone="UTC",
                           draft=dict(body="*Hello*", target=dict(chatId="fixture-chat")),
                           path="/chats/fixture-chat/messages", payload=dict(body=dict(content="<b>Hello</b>")))
        self.auth = Mock(return_value=("account-A", "ephemeral-token"))
        self.send = Mock(return_value={"id": "delivered-1"})
        with Outbox(self.path) as queue:
            queue.put(self.id, "account-A", self.record, now=1)

    def test_persistence_permissions_no_tokens_and_enqueue_idempotency(self):
        with Outbox(self.path) as queue:
            queue.put(self.id, "account-A", self.record, now=2)
            self.assertEqual(1, len(queue.list()))
            self.assertEqual(self.record["draft"], queue.get(self.id)["draft"])
        self.assertEqual(0o600, self.path.stat().st_mode & 0o777)
        self.assertNotIn(b"ephemeral-token", self.path.read_bytes())

    def test_before_due_then_once_only_even_after_reopen(self):
        with Outbox(self.path) as queue:
            self.assertEqual("idle", queue.run_one(self.auth, self.send, now=999)["state"])
            self.auth.assert_not_called()
            self.assertEqual("sent", queue.run_one(self.auth, self.send, now=1000)["state"])
        with Outbox(self.path) as queue:
            self.assertEqual("idle", queue.run_one(self.auth, self.send, now=1001)["state"])
            self.assertEqual("sent", queue.put(self.id, "account-A", self.record, now=1002)["state"])
        self.send.assert_called_once_with(self.record, "ephemeral-token")

    def test_cancel_and_edit_with_revision_guard(self):
        with Outbox(self.path) as queue:
            held = queue.change(self.id, "held")
            queue.run_one(self.auth, self.send, now=1000)
            changed = dict(self.record, sendAt=2000)
            with self.assertRaises(ValueError):
                queue.put(self.id, "account-A", changed, revision=0, now=10)
            queue.put(self.id, "account-A", changed, revision=held["revision"], now=10)
            queue.change(self.id, "cancelled")
            queue.run_one(self.auth, self.send, now=2000)
        self.send.assert_not_called()

    def test_auth_failure_does_not_claim_and_different_account_holds(self):
        with Outbox(self.path) as queue:
            self.auth.side_effect = RuntimeError("offline")
            with self.assertRaises(RuntimeError):
                queue.run_one(self.auth, self.send, now=1000)
            self.assertEqual("scheduled", queue.get(self.id)["state"])
            self.auth.side_effect = None
            self.auth.return_value = ("account-B", "token")
            self.assertEqual("held", queue.run_one(self.auth, self.send, now=1000)["state"])
        self.send.assert_not_called()

    def test_missed_window_held_without_authentication(self):
        with Outbox(self.path) as queue:
            queue.run_one(self.auth, self.send, grace=60, now=1061)
            self.assertEqual("held", queue.get(self.id)["state"])
        self.auth.assert_not_called()

    def test_safe_retry_after_429_not_before_then_success(self):
        self.send.side_effect = [RetryLater(120), {"id": "sent-after-429"}]
        with Outbox(self.path) as queue:
            self.assertEqual("retry", queue.run_one(self.auth, self.send, now=1000)["state"])
            queue.run_one(self.auth, self.send, now=1119)
            self.assertEqual(1, self.send.call_count)
            self.assertEqual("sent", queue.run_one(self.auth, self.send, now=1120)["state"])
        self.assertEqual(2, self.send.call_count)

    def test_ambiguous_and_missing_ack_never_retry(self):
        for result in (TimeoutError(), {"not-an-id": True}):
            path = self.path.parent / str(id(result))
            with Outbox(path) as queue:
                queue.put(self.id, "account-A", self.record, now=0)
                send = Mock(side_effect=result) if isinstance(result, Exception) else Mock(return_value=result)
                self.assertEqual("uncertain", queue.run_one(self.auth, send, now=1000)["state"])
                queue.run_one(self.auth, send, now=1500)
                with self.assertRaises(ValueError):
                    queue.change(self.id, "held")
                send.assert_called_once()

    def test_crash_after_claim_survives_restart_without_replay(self):
        with Outbox(self.path) as queue:
            with self.assertRaises(KeyboardInterrupt):
                queue.run_one(self.auth, Mock(side_effect=KeyboardInterrupt), now=1000)
        with Outbox(self.path) as queue:
            queue.run_one(self.auth, self.send, now=1400)
            self.assertEqual("uncertain", queue.get(self.id)["state"])
        self.send.assert_not_called()

    def test_two_workers_only_one_claim(self):
        started, finish = threading.Event(), threading.Event()
        def send(*_):
            started.set()
            finish.wait(5)
            return {"id": "sent"}
        def worker():
            with Outbox(self.path) as queue:
                queue.run_one(self.auth, send, now=1000)
        thread = threading.Thread(target=worker)
        thread.start()
        try:
            self.assertTrue(started.wait(5))
            with Outbox(self.path) as queue:
                queue.run_one(self.auth, self.send, now=1000)
                with self.assertRaises(ValueError):
                    queue.change(self.id, "cancelled")
        finally:
            finish.set()
            thread.join(5)
        self.send.assert_not_called()

    def test_cancel_during_authentication_wins_and_slow_auth_holds(self):
        def cancel():
            with Outbox(self.path) as other:
                other.change(self.id, "cancelled")
            return "account-A", "token"
        with Outbox(self.path) as queue:
            queue.run_one(cancel, self.send, now=1000)
            self.assertEqual("cancelled", queue.get(self.id)["state"])
            queue.put("fixture-message-0002", "account-A", self.record, now=1)
            with patch("teams4e_outbox.time.time", side_effect=[1000, 2000]):
                queue.run_one(self.auth, self.send, grace=60)
            self.assertEqual("held", queue.get("fixture-message-0002")["state"])
        self.send.assert_not_called()

    def test_repeated_throttling_stops_and_known_rejection_holds(self):
        with Outbox(self.path) as queue:
            self.send.side_effect = RetryLater(1)
            for now in range(1000, 1005):
                result = queue.run_one(self.auth, self.send, now=now)
            self.assertEqual("held", result["state"])
            queue.run_one(self.auth, self.send, now=1010)
            self.assertEqual(5, self.send.call_count)
            queue.put("fixture-message-0002", "account-A", self.record, now=1)
            self.send.side_effect = Rejected()
            self.assertEqual("held", queue.run_one(self.auth, self.send, now=1000)["state"])

    def test_changed_payload_never_replaces_pending_and_nonfinite_rejected(self):
        with Outbox(self.path) as queue:
            with self.assertRaises(ValueError):
                queue.put(self.id, "account-A", dict(self.record, sendAt=2000), now=1)
            with self.assertRaises(ValueError):
                queue.put("fixture-message-0002", "account-A", dict(self.record, sendAt=float("nan")), now=1)


class TransportTests(unittest.TestCase):
    def test_scheduled_posts_do_not_inherit_5xx_retries(self):
        for status, exception in [(429, RetryLater), (403, Rejected), (503, graph.BackendError)]:
            error = urllib.error.HTTPError("https://graph.microsoft.com", status, "fixture", {"Retry-After": "120"}, io.BytesIO(b"{}"))
            with patch.object(graph.urllib.request, "urlopen", side_effect=error) as post, \
                 patch.object(graph.GRAPH_REQUEST_BUDGET, "acquire"), \
                 patch.object(graph.GRAPH_REQUEST_BUDGET, "defer"), \
                 patch.object(graph, "mock_enabled", return_value=False):
                with self.assertRaises(exception):
                    graph.outbox_send(dict(path="/chats/test/messages", payload={}), "fake-token")
                self.assertEqual(1, post.call_count)
                self.assertFalse(graph.OUTBOX_SEND.get())

    def test_frozen_quote_channel_and_source_are_preserved(self):
        value = dict(when=dict(sendAt=2000, displayTime="fixture", zone="UTC"),
                     message="<p>Hello</p>", contentType="html",
                     draft=dict(body="*Hello*", editor="org", contentType="text", mentions=[],
                                target=dict(kind="chat", chatId="chat/a", label="Fixture"),
                                replyTo=dict(id="parent", body=dict(content="Old message"),
                                             **{"from": {"user": {"id": "person", "displayName": "Example"}}})))
        record = graph.outbox_record(value, "fake")
        self.assertEqual("*Hello*", record["draft"]["body"])
        self.assertEqual("/chats/chat%2Fa/messages", record["path"])
        self.assertEqual("parent", record["payload"]["attachments"][0]["id"])
        value["draft"]["target"] = dict(kind="channel", teamId="team", channelId="channel")
        self.assertEqual("/teams/team/channels/channel/messages/parent/replies", graph.outbox_record(value, "fake")["path"])

    def test_mock_and_live_queue_files_are_isolated(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "outbox")
            with patch.object(graph, "mock_enabled", return_value=True), patch.object(graph, "ensure_graph_token", side_effect=AssertionError):
                self.assertEqual([], graph.execute(["teams", "outbox", "list", "--store", path])[0])
            self.assertTrue(Path(path + ".mock").exists())
            self.assertFalse(Path(path).exists())

    def test_cli_contract_schedules_and_delivers_to_synthetic_chat_once(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.dict(os.environ, {"TEAMS4E_MOCK": "1", "TEAMS4E_MOCK_STATE": directory + "/tenant.json"}), \
             patch.object(graph.urllib.request, "urlopen", side_effect=AssertionError("No network allowed")):
            tenant = graph.MockTenant()
            chat = tenant.state["chats"][0]
            path = directory + "/outbox"
            due = graph.time.time() + 100
            value = dict(id="mock-scheduled-0001", revision=None,
                         when=dict(sendAt=due, displayTime="synthetic future", zone="UTC"),
                         message="<p>Scheduled fixture</p>", contentType="html",
                         draft=dict(body="Scheduled fixture", editor="org", contentType="text",
                                    mentions=[], target=dict(kind="chat", chatId=chat["id"], label="Example")))
            command = ["teams", "outbox", "put", "--store", path, "--payload", json.dumps(value)]
            self.assertEqual("scheduled", graph.execute(command)[0]["state"])
            self.assertEqual("scheduled", graph.execute(command)[0]["state"])
            with Outbox(path + ".mock") as queue:
                result = queue.run_one(graph.outbox_identity, graph.outbox_send, now=due)
                self.assertEqual("sent", result["state"])
                queue.run_one(graph.outbox_identity, graph.outbox_send, now=due + 1)
            messages = graph.MockTenant().state["chatMessages"][chat["id"]]
            self.assertEqual(1, sum(message["id"] == result["message_id"] for message in messages))
            self.assertEqual("<p>Scheduled fixture</p>", messages[-1]["body"]["content"])
            self.assertNotIn(b"access_token", Path(path + ".mock").read_bytes())


if __name__ == "__main__":
    unittest.main()
