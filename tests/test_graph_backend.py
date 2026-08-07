"""Offline tests for the passive msteams Microsoft Graph backend."""

from __future__ import annotations

import base64
import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.parse
from pathlib import Path
from unittest import mock


BIN_DIR = Path(__file__).resolve().parents[1] / "bin"
sys.path.insert(0, str(BIN_DIR))

import msteams_graph as backend  # noqa: E402
from msteams_cache import TeamsCache  # noqa: E402
from msteams_mock import MockTenant  # noqa: E402


def jwt(claims: dict) -> str:
  """Create an unsigned JWT-shaped value for claim-decoding tests."""
  encoded = base64.urlsafe_b64encode(
      json.dumps(claims).encode("utf-8")
  ).rstrip(b"=").decode("ascii")
  return f"header.{encoded}.signature"


def write_credentials(
    path: Path,
    *,
    token: str = "graph-token",
    expires_at: int | None = None,
    refresh_token: str = "refresh-token",
) -> None:
  """Write one minimal shared M365 credential entry."""
  if expires_at is None:
    expires_at = int((time.time() + 3600) * 1000)
  store = {
      "m365|test": {
          "server_name": backend.SERVER_NAME,
          "server_url": backend.SERVER_URL,
          "client_id": "shared-client-id",
          "refresh_token": refresh_token,
          "graph_access_token": token,
          "graph_expires_at": expires_at,
      }
  }
  path.write_text(json.dumps(store), encoding="utf-8")


class GraphBackendTests(unittest.TestCase):

  def setUp(self) -> None:
    backend.TOKEN_COMMAND_CACHE = None

  def test_status_decodes_shared_identity_without_refreshing(self) -> None:
    with tempfile.TemporaryDirectory() as directory:
      path = Path(directory) / "credentials.json"
      token = jwt({
          "preferred_username": "user@example.com",
          "tid": "tenant-id",
          "oid": "user-id",
          "appid": "existing-app-id",
      })
      write_credentials(path, token=token)

      status = backend.status_payload(path)

      self.assertEqual("user@example.com", status["connectedAs"])
      self.assertEqual("tenant-id", status["appTenant"])
      self.assertEqual("user-id", status["userId"])
      self.assertEqual("SharedGraphOAuth", status["authType"])
      self.assertEqual("fresh", status["graphTokenStatus"])

  def test_status_reports_logged_out_when_store_is_absent(self) -> None:
    with tempfile.TemporaryDirectory() as directory:
      path = Path(directory) / "missing.json"
      self.assertEqual("Logged out", backend.status_payload(path))

  def test_external_token_command_returns_short_lived_envelope(self) -> None:
    with tempfile.TemporaryDirectory() as directory:
      path = Path(directory) / "credentials.json"
      expires_at = int((time.time() + 3600) * 1000)
      write_credentials(path, token="shared-graph-token", expires_at=expires_at)
      output = io.StringIO()

      with mock.patch.dict(
          os.environ, {"MSTEAMS_CREDENTIALS": str(path)}, clear=False
      ), contextlib.redirect_stdout(output):
        self.assertEqual(0, backend.dispatch(["token", "--output", "json"]))

      payload = json.loads(output.getvalue())
      self.assertEqual("shared-graph-token", payload["access_token"])
      self.assertEqual(expires_at // 1000, payload["expires_at"])
      self.assertNotIn("refresh_token", payload)

  def test_argv_token_provider_is_cached_and_exposes_no_refresh_token(self) -> None:
    expires_at = int(time.time()) + 3600
    token = jwt({
        "preferred_username": "user@example.com",
        "oid": "user-id",
        "exp": expires_at,
    })
    completed = subprocess.CompletedProcess(
        ["token-provider", "--json"],
        0,
        stdout=json.dumps({"access_token": token, "expires_at": expires_at}),
        stderr="",
    )
    environment = {
        "MSTEAMS_TOKEN_COMMAND": json.dumps(["token-provider", "--json"]),
    }
    with (
        mock.patch.dict(os.environ, environment, clear=False),
        mock.patch.object(backend.subprocess, "run", return_value=completed) as run,
    ):
      first = backend.external_token_payload(Path("unused"))
      second = backend.external_token_payload(Path("unused"))
      status = backend.status_payload(Path("unused"))
    run.assert_called_once()
    self.assertEqual(token, first["access_token"])
    self.assertEqual(first, second)
    self.assertEqual(expires_at, first["expires_at"])
    self.assertEqual("ExternalTokenCommand", status["authType"])
    self.assertEqual("user@example.com", status["connectedAs"])
    self.assertNotIn("refresh_token", first)

  def test_stale_graph_token_refreshes_only_through_bootstrap(self) -> None:
    with tempfile.TemporaryDirectory() as directory:
      path = Path(directory) / "credentials.json"
      write_credentials(path, token="stale", expires_at=1)

      def refresh(requested_path: Path) -> None:
        self.assertEqual(path, requested_path)
        write_credentials(path, token="fresh")

      with mock.patch.object(backend, "run_bootstrap", side_effect=refresh) as run:
        self.assertEqual("fresh", backend.ensure_graph_token(path))
      run.assert_called_once_with(path)

  def test_graph_collection_follows_next_link(self) -> None:
    next_url = "https://graph.microsoft.com/v1.0/me/chats?$skiptoken=next"
    pages = [
        {"value": [{"id": "one"}], "@odata.nextLink": next_url},
        {"value": [{"id": "two"}]},
    ]
    with mock.patch.object(backend, "graph_json", side_effect=pages) as request:
      result = backend.graph_collection("/me/chats?$top=50", "token")
    self.assertEqual([{"id": "one"}, {"id": "two"}], result)
    self.assertEqual(next_url, request.call_args_list[1].args[0])

  def test_graph_collection_rejects_repeated_next_link(self) -> None:
    repeated = "https://graph.microsoft.com/v1.0/me/chats?$skiptoken=loop"
    with mock.patch.object(
        backend,
        "graph_json",
        side_effect=[
            {"value": [], "@odata.nextLink": repeated},
            {"value": [], "@odata.nextLink": repeated},
        ],
    ):
      with self.assertRaisesRegex(backend.BackendError, "repeated"):
        backend.graph_collection("/me/chats", "token")

  def test_graph_request_never_forwards_token_to_external_host(self) -> None:
    with mock.patch.object(backend.urllib.request, "urlopen") as request:
      with self.assertRaisesRegex(backend.BackendError, "non-Graph"):
        backend.graph_json("https://example.com/collect", "secret-token")
    request.assert_not_called()

  def test_message_query_pairs_filter_with_matching_order(self) -> None:
    with mock.patch.object(backend, "graph_collection", return_value=[]) as request:
      backend.list_messages(
          "19:opaque@thread.v2", "token", "2026-08-01T00:00:00Z"
      )
    path = request.call_args.args[0]
    parsed = urllib.parse.urlparse(path)
    query = urllib.parse.parse_qs(parsed.query)
    self.assertIn("19%3Aopaque%40thread.v2", path)
    self.assertEqual(["lastModifiedDateTime desc"], query["$orderby"])
    self.assertEqual(
        ["lastModifiedDateTime gt 2026-08-01T00:00:00Z"], query["$filter"]
    )

  def test_message_query_stops_at_requested_preview_limit(self) -> None:
    with mock.patch.object(backend, "graph_collection", return_value=[]) as request:
      backend.list_messages("chat-id", "token", limit=75)
    self.assertEqual(75, request.call_args.kwargs["limit"])

  def test_chat_list_requests_last_message_preview(self) -> None:
    with mock.patch.object(backend, "graph_collection", return_value=[]) as request:
      backend.list_chats("token")
    query = urllib.parse.parse_qs(urllib.parse.urlparse(request.call_args.args[0]).query)
    self.assertEqual(["lastMessagePreview"], query["$expand"])

  def test_meeting_context_uses_linked_calendar_event_and_members(self) -> None:
    def request(path: str, token: str, **kwargs: object) -> dict[str, object]:
      self.assertEqual("token", token)
      if path.startswith("/chats/"):
        return {
            "id": "meeting-chat",
            "chatType": "meeting",
            "onlineMeetingInfo": {"calendarEventId": "event:id"},
        }
      self.assertIn("/me/events/event%3Aid", path)
      self.assertIn("%24select=", path)
      selected = urllib.parse.parse_qs(
          urllib.parse.urlparse(path).query
      )["$select"][0].split(",")
      self.assertTrue({
          "location", "locations", "isCancelled", "responseStatus", "showAs"
      }.issubset(selected))
      self.assertEqual(
          {"Prefer": 'outlook.timezone="UTC"'}, kwargs["request_headers"]
      )
      return {
          "start": {"dateTime": "2026-08-10T07:30:00", "timeZone": "UTC"},
          "end": {"dateTime": "2026-08-10T08:15:00", "timeZone": "UTC"},
      }

    members = [{"displayName": "Ada Lovelace"}]
    with (
        mock.patch.object(backend, "graph_json", side_effect=request) as graph,
        mock.patch.object(backend, "list_members", return_value=members),
    ):
      result = backend.get_meeting_context("meeting-chat", "token")
    self.assertEqual(2, graph.call_count)
    self.assertEqual(members, result["members"])
    self.assertEqual(
        "2026-08-10T07:30:00", result["event"]["start"]["dateTime"]
    )

  def test_meeting_event_batch_is_event_only_bounded_and_ordered(self) -> None:
    meetings = [
        {"chatId": "chat-1", "eventId": "event-1"},
        {"chatId": "chat-2", "eventId": "event-2"},
    ]

    def event(event_id: str, token: str) -> dict[str, str]:
      self.assertEqual("token", token)
      if event_id == "event-2":
        raise backend.BackendError("calendar denied")
      return {"id": event_id}

    with mock.patch.object(
        backend, "get_calendar_event", side_effect=event
    ) as request:
      result = backend.list_meeting_events_batch(
          meetings, "token", meeting_concurrency=2
      )

    self.assertEqual(2, request.call_count)
    self.assertEqual(["chat-1", "chat-2"], [item["chatId"] for item in result])
    self.assertEqual("event-1", result[0]["event"]["id"])
    self.assertIn("denied", result[1]["eventError"])

  def test_meeting_context_keeps_members_when_calendar_access_fails(self) -> None:
    with (
        mock.patch.object(
            backend,
            "graph_json",
            side_effect=[
                {
                    "chatType": "meeting",
                    "onlineMeetingInfo": {"calendarEventId": "event-id"},
                },
                backend.BackendError("Microsoft Graph HTTP 403: denied"),
            ],
        ),
        mock.patch.object(
            backend, "list_members", return_value=[{"displayName": "Ada"}]
        ),
    ):
      result = backend.get_meeting_context("meeting-chat", "token")
    self.assertEqual("Ada", result["members"][0]["displayName"])
    self.assertIn("403", result["eventError"])

  def test_meeting_transcript_resolves_join_url_and_latest_vtt(self) -> None:
    context = {
        "event": {
            "subject": "Architecture review",
            "onlineMeeting": {"joinUrl": "https://teams.test/join?id=one"},
        },
        "onlineMeetingInfo": {},
    }
    transcripts = [
        {"id": "older", "endDateTime": "2026-08-01T09:00:00Z"},
        {"id": "latest:id", "endDateTime": "2026-08-02T09:00:00Z"},
    ]
    with (
        mock.patch.object(backend, "get_meeting_context", return_value=context),
        mock.patch.object(
            backend,
            "graph_json",
            return_value={"value": [{"id": "meeting:id"}]},
        ) as graph,
        mock.patch.object(
            backend, "graph_collection", return_value=transcripts
        ) as collection,
        mock.patch.object(
            backend, "graph_text", return_value="WEBVTT\n\n<v Ada>Hello</v>"
        ) as content,
    ):
      result = backend.get_meeting_transcript("chat:id", "token")
    filter_query = urllib.parse.parse_qs(
        urllib.parse.urlparse(graph.call_args.args[0]).query
    )["$filter"][0]
    self.assertEqual("JoinWebUrl eq 'https://teams.test/join?id=one'", filter_query)
    self.assertIn("meeting%3Aid/transcripts", collection.call_args.args[0])
    self.assertIn("latest%3Aid/content", content.call_args.args[0])
    self.assertEqual("text/vtt", content.call_args.kwargs["accept"])
    self.assertEqual("latest:id", result["transcript"]["id"])
    self.assertEqual("text/vtt", result["contentType"])

  def test_meeting_transcript_falls_back_without_speaker_attribution(self) -> None:
    context = {
        "event": {
            "onlineMeeting": {"joinUrl": "https://teams.test/join?id=one"},
        },
        "onlineMeetingInfo": {},
    }
    with (
        mock.patch.object(backend, "get_meeting_context", return_value=context),
        mock.patch.object(
            backend,
            "graph_json",
            return_value={"value": [{"id": "meeting-id"}]},
        ),
        mock.patch.object(
            backend,
            "graph_collection",
            return_value=[{"id": "transcript-id"}],
        ),
        mock.patch.object(
            backend,
            "graph_text",
            side_effect=[
                backend.BackendError(
                    "Microsoft Graph transcript HTTP 403: "
                    "SpeakerAttributionNotAllowed"
                ),
                "00:00:00.000 --> 00:00:02.000\nHello",
            ],
        ) as content,
    ):
      result = backend.get_meeting_transcript("chat-id", "token")
    self.assertEqual(2, content.call_count)
    self.assertEqual("text/vtt", content.call_args_list[0].kwargs["accept"])
    self.assertEqual(
        "application/vnd.microsoft.graph.transcript+text",
        content.call_args_list[1].kwargs["accept"],
    )
    self.assertEqual(
        "application/vnd.microsoft.graph.transcript+text",
        result["contentType"],
    )
    self.assertIn("Hello", result["content"])

  def test_member_batch_uses_tui_equivalent_calls_and_preserves_order(self) -> None:
    def members(chat_id: str, token: str) -> list[dict[str, str]]:
      self.assertEqual("token", token)
      return [{"displayName": chat_id}]

    with mock.patch.object(backend, "list_members", side_effect=members) as request:
      result = backend.list_chat_members_batch(
          ["chat-2", "chat-1", "chat-2"],
          "token",
          member_concurrency=2,
      )
    self.assertEqual(2, request.call_count)
    self.assertEqual(["chat-2", "chat-1"], [item["chatId"] for item in result])
    self.assertTrue(all(item["membersLoaded"] for item in result))
    self.assertEqual("chat-2", result[0]["members"][0]["displayName"])

  def test_bounded_collection_stops_before_another_page(self) -> None:
    with mock.patch.object(
        backend,
        "graph_json",
        return_value={
            "value": [{"id": "chat-1"}, {"id": "chat-2"}],
            "@odata.nextLink": "/me/chats?page=2",
        },
    ) as request:
      result = backend.graph_collection("/me/chats", "token", limit=1)
    self.assertEqual([{"id": "chat-1"}], result)
    request.assert_called_once_with("/me/chats", "token")

  def test_send_posts_plain_text_to_existing_chat(self) -> None:
    with mock.patch.object(
        backend, "graph_json", return_value={"id": "message-id"}
    ) as request:
      result = backend.send_message("chat:id", "Line one\nLine two", "token")
    self.assertEqual("message-id", result["id"])
    self.assertEqual("POST", request.call_args.kwargs["method"])
    self.assertEqual(
        {"body": {"contentType": "text", "content": "Line one\nLine two"}},
        request.call_args.kwargs["payload"],
    )

  def test_reply_uses_documented_reply_with_quote_action(self) -> None:
    with mock.patch.object(
        backend, "graph_json", return_value={"id": "message-2"}
    ) as request:
      backend.send_message(
          "chat:id", "Reply <safely>\nSecond line", "token", "message-1"
      )
    self.assertIn("/chats/chat%3Aid/messages/replyWithQuote", request.call_args.args[0])
    payload = request.call_args.kwargs["payload"]
    self.assertEqual(["message-1"], payload["messageIds"])
    self.assertEqual(
        {"contentType": "text", "content": "Reply <safely>\nSecond line"},
        payload["replyMessage"]["body"],
    )

  def test_mark_read_and_unread_use_signed_in_identity(self) -> None:
    token = jwt({"oid": "user-id", "tid": "tenant-id"})
    with mock.patch.object(backend, "graph_json", return_value={}) as request:
      backend.set_chat_read_state("chat:id", token, unread=False)
      backend.set_chat_read_state("chat:id", token, unread=True)
    read, unread = request.call_args_list
    self.assertIn("/markChatReadForUser", read.args[0])
    self.assertIn("/markChatUnreadForUser", unread.args[0])
    self.assertEqual(
        {"user": {"id": "user-id", "tenantId": "tenant-id"}},
        read.kwargs["payload"],
    )
    self.assertEqual("POST", unread.kwargs["method"])

  def test_participant_lookup_returns_existing_one_to_one_chat(self) -> None:
    token = jwt({"preferred_username": "user@example.com"})
    chats = [
        {"id": "meeting", "chatType": "meeting"},
        {"id": "direct", "chatType": "oneOnOne"},
    ]
    members = [
        {"email": "user@example.com"},
        {"email": "ada@example.com"},
    ]
    with mock.patch.object(backend, "list_chats", return_value=chats), \
         mock.patch.object(backend, "list_members", return_value=members) as request:
      chat = backend.find_chat_by_participants("ADA@example.com", token)
    self.assertEqual("direct", chat["id"])
    request.assert_called_once_with("direct", token)

  def test_server_message_search_returns_ephemeral_hydration_context(self) -> None:
    response = {
        "value": [{
            "hitsContainers": [{
                "hits": [
                    {
                        "rank": 1,
                        "summary": "Ada discussed the cache",
                        "resource": {
                            "id": "chat-message",
                            "chatId": "chat:id",
                            "body": {"contentType": "text", "content": "Cache"},
                        },
                    },
                    {
                        "rank": 2,
                        "resource": {
                            "id": "reply:id",
                            "replyToId": "root:id",
                            "channelIdentity": {
                                "teamId": "team:id",
                                "channelId": "channel:id",
                            },
                        },
                    },
                ]
            }]
        }]
    }
    with mock.patch.object(backend, "graph_json", return_value=response) as request:
      results = backend.search_messages("cache AND Graph", "token", offset=5, limit=20)
    self.assertEqual("/search/query", request.call_args.args[0])
    self.assertEqual("POST", request.call_args.kwargs["method"])
    graph_request = request.call_args.kwargs["payload"]["requests"][0]
    self.assertEqual("cache AND Graph", graph_request["query"]["queryString"])
    self.assertEqual(5, graph_request["from"])
    self.assertEqual(20, graph_request["size"])
    self.assertEqual("chat:id", results[0]["searchContext"]["scopeId"])
    self.assertEqual("root:id", results[1]["searchContext"]["rootMessageId"])

  def test_persistent_server_protocol_returns_correlated_json(self) -> None:
    input_stream = io.StringIO('{"id":7,"args":["status"]}\n')
    output = io.StringIO()
    with (
        mock.patch.object(backend.sys, "stdin", input_stream),
        mock.patch.object(backend, "execute", return_value=({"ready": True}, "json")),
        contextlib.redirect_stdout(output),
    ):
      self.assertEqual(0, backend.serve())
    response = json.loads(output.getvalue())
    self.assertEqual(7, response["id"])
    self.assertTrue(response["ok"])
    self.assertEqual({"ready": True}, response["result"])

  def test_status_command_outputs_cli_compatible_json_string(self) -> None:
    with tempfile.TemporaryDirectory() as directory:
      path = Path(directory) / "missing.json"
      output = io.StringIO()
      with mock.patch.dict(
          backend.os.environ, {"MSTEAMS_CREDENTIALS": str(path)}, clear=False
      ), contextlib.redirect_stdout(output):
        self.assertEqual(0, backend.dispatch(["status", "--output", "json"]))
      self.assertEqual("Logged out", json.loads(output.getvalue()))

  def test_outgoing_body_builds_structured_mentions_and_html(self) -> None:
    body, mentions = backend.outgoing_body(
        "Hello @Ada Lovelace\nSecond line",
        content_type="text",
        mention_specs=["ada-id|Ada Lovelace"],
        attachment_tags=['<attachment id="file"></attachment>'],
    )
    self.assertEqual("html", body["contentType"])
    self.assertIn('<at id="0">Ada Lovelace</at>', body["content"])
    self.assertIn("Second line", body["content"])
    self.assertEqual("ada-id", mentions[0]["mentioned"]["user"]["id"])
    with self.assertRaisesRegex(backend.BackendError, "placeholder"):
      backend.outgoing_body(
          "Hello without a recipient",
          content_type="text",
          mention_specs=["ada-id|Ada Lovelace"],
          attachment_tags=[],
      )

  def test_channel_message_send_and_reply_use_documented_paths(self) -> None:
    with mock.patch.object(
        backend, "graph_json", return_value={"id": "result"}
    ) as request:
      backend.send_channel_message("team:id", "channel:id", "Root", "token")
      backend.send_channel_message(
          "team:id", "channel:id", "Reply", "token", reply_to_id="root:id"
      )
    root, reply = request.call_args_list
    self.assertIn("/teams/team%3Aid/channels/channel%3Aid/messages", root.args[0])
    self.assertIn("/messages/root%3Aid/replies", reply.args[0])
    self.assertEqual("POST", reply.kwargs["method"])

  def test_channel_list_expands_replies_and_follows_nested_page(self) -> None:
    next_url = (
        "https://graph.microsoft.com/v1.0/teams/team/channels/channel/"
        "messages/root/replies?$skiptoken=next"
    )
    with mock.patch.object(
        backend,
        "graph_json",
        side_effect=[
            {
                "value": [
                    {
                        "id": "root",
                        "replies": [{"id": "reply-1"}],
                        "replies@odata.nextLink": next_url,
                    }
                ]
            },
            {"value": [{"id": "reply-2"}]},
        ],
    ) as request:
      roots = backend.list_channel_messages("team", "channel", "token")
      replies = backend.expanded_channel_replies(roots[0], "token")
    first_url = request.call_args_list[0].args[0]
    self.assertIn("%24expand=replies", first_url)
    self.assertEqual(next_url, request.call_args_list[1].args[0])
    self.assertEqual(["reply-1", "reply-2"], [item["id"] for item in replies])

  def test_message_mutations_build_chat_and_channel_reply_paths(self) -> None:
    with mock.patch.object(
        backend, "graph_identity", return_value=("user:id", "tenant:id")
    ), mock.patch.object(backend, "graph_json", return_value={}) as request:
      backend.mutate_message(
          "react", "chat", "message:id", "token",
          chat_id="chat:id", reaction="👍"
      )
      backend.mutate_message(
          "restore", "channel", "reply:id", "token",
          team_id="team:id", channel_id="channel:id",
          root_message_id="root:id",
      )
    reaction, restore = request.call_args_list
    self.assertIn("/chats/chat%3Aid/messages/message%3Aid/setReaction", reaction.args[0])
    self.assertIn(
        "/messages/root%3Aid/replies/reply%3Aid/undoSoftDelete",
        restore.args[0],
    )

  def test_chat_soft_delete_uses_signed_in_user_path_and_empty_body(self) -> None:
    with mock.patch.object(
        backend, "graph_identity", return_value=("user:id", "tenant:id")
    ), mock.patch.object(backend, "graph_json", return_value={}) as request:
      backend.mutate_message(
          "delete", "chat", "message:id", "token", chat_id="chat:id"
      )
    self.assertIn(
        "/users/user%3Aid/chats/chat%3Aid/messages/message%3Aid/softDelete",
        request.call_args.args[0],
    )
    self.assertNotIn("payload", request.call_args.kwargs)

  def test_create_chat_includes_current_user_and_resolved_members(self) -> None:
    with mock.patch.object(
        backend, "graph_json", side_effect=[{"id": "me-id"}, {"id": "chat-id"}]
    ) as request, mock.patch.object(
        backend, "resolve_user_ids", return_value=["ada-id", "grace-id"]
    ):
      result = backend.create_chat(
          ["ada@example.test", "grace@example.test"], "token", topic="Group"
      )
    self.assertEqual("chat-id", result["id"])
    payload = request.call_args_list[1].kwargs["payload"]
    self.assertEqual("group", payload["chatType"])
    self.assertEqual("Group", payload["topic"])
    self.assertEqual(3, len(payload["members"]))
    self.assertIn("me-id", payload["members"][0]["user@odata.bind"])

  def test_sqlite_cache_round_trip_search_and_private_mode(self) -> None:
    with tempfile.TemporaryDirectory() as directory:
      path = Path(directory) / "nested" / "teams.sqlite3"
      message = {
          "id": "message-1",
          "createdDateTime": "2026-08-02T07:00:00Z",
          "lastModifiedDateTime": "2026-08-02T07:00:00Z",
          "from": {"user": {"displayName": "Ada"}},
          "body": {"contentType": "text", "content": "Paging model review"},
      }
      with TeamsCache(path) as cache:
        cache.upsert_resources("chat", [{"id": "chat-1", "topic": "Atlas"}])
        first = cache.upsert_messages("chat", "chat-1", [message])
        second = cache.upsert_messages("chat", "chat-1", [message])
        results = cache.search("paging review")
        status = cache.status()
      self.assertEqual(1, first["inserted"])
      self.assertEqual(1, second["unchanged"])
      self.assertEqual("message-1", results[0]["id"])
      self.assertEqual("chat-1", results[0]["cacheContext"]["scopeId"])
      self.assertEqual(1, status["messages"]["chat"])
      self.assertEqual(0o600, path.stat().st_mode & 0o777)

  def test_partial_sync_keeps_previous_watermark_for_retry(self) -> None:
    with tempfile.TemporaryDirectory() as directory:
      path = Path(directory) / "teams.sqlite3"
      previous = "2026-08-01T10:00:00Z"
      with TeamsCache(path) as cache:
        cache.set_meta("last_sync", previous)
        cache.connection.commit()
      with mock.patch.dict(
          os.environ, {"MSTEAMS_CACHE": str(path)}, clear=False
      ), mock.patch.object(
          backend,
          "list_chats",
          return_value=[
              {"id": "chat-1", "lastUpdatedDateTime": "2026-08-02T10:00:00Z"}
          ],
      ), mock.patch.object(
          backend, "list_messages", side_effect=backend.BackendError("retry me")
      ):
        result = backend.sync_cache("token")
      with TeamsCache(path) as cache:
        self.assertEqual(previous, cache.get_meta("last_sync"))
      self.assertEqual(1, len(result["errors"]))
      self.assertIn("retry me", result["errors"][0]["error"])

  def test_mock_tenant_mutations_are_persistent_and_undoable(self) -> None:
    with tempfile.TemporaryDirectory() as directory:
      state_path = Path(directory) / "tenant.json"
      tenant = MockTenant(state_path)
      sent = tenant.execute([
          "teams", "chat", "message", "send", "--chatId", "mock-chat-ada",
          "--message", "Draft to edit", "--contentType", "text",
      ])
      message_id = sent["id"]
      context = [
          "--scope", "chat", "--chatId", "mock-chat-ada",
          "--messageId", message_id,
      ]
      tenant.execute(["teams", "message", "edit", *context,
                      "--message", "Edited body"])
      tenant.execute(["teams", "message", "react", *context,
                      "--reaction", "like"])
      tenant.execute(["teams", "message", "delete", *context])
      tenant.execute(["teams", "message", "restore", *context])
      reloaded = MockTenant(state_path)
      messages = reloaded.execute([
          "teams", "chat", "message", "list", "--chatId", "mock-chat-ada"
      ])
      restored = next(item for item in messages if item["id"] == message_id)
      self.assertEqual("Edited body", restored["body"]["content"])
      self.assertIsNone(restored["deletedDateTime"])
      self.assertEqual("like", restored["reactions"][0]["reactionType"])

  def test_mock_chat_reply_contains_renderable_quote_reference(self) -> None:
    with tempfile.TemporaryDirectory() as directory:
      tenant = MockTenant(Path(directory) / "tenant.json")
      reply = tenant.execute([
          "teams", "chat", "message", "send",
          "--chatId", "mock-chat-ada",
          "--message", "Quoted reply",
          "--replyToId", "mock-chat-ada-2",
      ])
    reference = reply["attachments"][0]
    content = json.loads(reference["content"])
    self.assertEqual("messageReference", reference["contentType"])
    self.assertEqual("mock-chat-ada-2", content["messageId"])
    self.assertTrue(content["messagePreview"])

  def test_mock_sync_populates_searchable_chats_channels_and_replies(self) -> None:
    with tempfile.TemporaryDirectory() as directory:
      state_path = Path(directory) / "tenant.json"
      cache_path = Path(directory) / "teams.sqlite3"
      with mock.patch.dict(
          os.environ,
          {
              "MSTEAMS_MOCK_STATE": str(state_path),
              "MSTEAMS_CACHE": str(cache_path),
          },
          clear=False,
      ):
        tenant = MockTenant(state_path)
        summary = tenant.execute(["teams", "sync", "--scope", "all"])
        results = tenant.execute([
            "teams", "cache", "search", "--query", "native workflow"
        ])
      self.assertEqual([], summary["errors"])
      self.assertEqual(2, summary["teams"])
      self.assertTrue(results)
      self.assertEqual("channel", results[0]["cacheContext"]["scopeKind"])

  def test_mock_supports_server_search_and_meeting_transcript(self) -> None:
    with tempfile.TemporaryDirectory() as directory:
      tenant = MockTenant(Path(directory) / "tenant.json")
      results = tenant.execute([
          "teams", "search", "messages", "--query", "native Teams workflow"
      ])
      transcript = tenant.execute([
          "teams", "meeting", "transcript",
          "--chatId", "mock-chat-future-meeting",
      ])
      events = tenant.execute([
          "teams", "meeting", "event", "batch", "--meetings",
          json.dumps([{
              "chatId": "mock-chat-future-meeting",
              "eventId": "mock-event-architecture-review",
          }]),
      ])
    self.assertTrue(results)
    self.assertEqual("channel", results[0]["searchContext"]["scopeKind"])
    self.assertEqual("text/vtt", transcript["contentType"])
    self.assertIn("Graph remains authoritative", transcript["content"])
    self.assertEqual("Video room 4", events[0]["event"]["location"]["displayName"])

  def test_mock_attachment_round_trip_uses_private_local_copy(self) -> None:
    with tempfile.TemporaryDirectory() as directory:
      root = Path(directory)
      state_path = root / "tenant.json"
      source = root / "notes.txt"
      source.write_text("attachment body", encoding="utf-8")
      tenant = MockTenant(state_path)
      message = tenant.execute([
          "teams", "chat", "message", "send", "--chatId", "mock-chat-ada",
          "--message", "Attached", "--attachment", str(source),
      ])
      destination = root / "downloads" / "notes.txt"
      result = tenant.execute([
          "teams", "attachment", "download",
          "--url", message["attachments"][0]["contentUrl"],
          "--destination", str(destination),
      ])
      self.assertEqual("attachment body", destination.read_text(encoding="utf-8"))
      self.assertEqual(len("attachment body"), result["bytes"])
      self.assertEqual(0o600, destination.stat().st_mode & 0o777)

  def test_mock_dispatch_reaches_send_and_cached_search_commands(self) -> None:
    with tempfile.TemporaryDirectory() as directory:
      state_path = Path(directory) / "tenant.json"
      cache_path = Path(directory) / "cache.sqlite3"
      environment = {
          "MSTEAMS_MOCK": "1",
          "MSTEAMS_MOCK_STATE": str(state_path),
          "MSTEAMS_CACHE": str(cache_path),
      }
      output = io.StringIO()
      with mock.patch.dict(os.environ, environment, clear=False), \
           contextlib.redirect_stdout(output):
        self.assertEqual(0, backend.dispatch([
            "teams", "chat", "message", "send",
            "--chatId", "mock-chat-ada", "--message", "Dispatch works",
        ]))
      self.assertEqual("Dispatch works", json.loads(output.getvalue())["body"]["content"])
      with mock.patch.dict(os.environ, environment, clear=False):
        backend.dispatch(["teams", "sync", "--scope", "all", "--output", "none"])
      output = io.StringIO()
      with mock.patch.dict(os.environ, environment, clear=False), \
           contextlib.redirect_stdout(output):
        backend.dispatch([
            "teams", "cache", "search", "--query", "Dispatch works"
        ])
      self.assertEqual(1, len(json.loads(output.getvalue())))

      def cached(args: list[str]) -> object:
        command_output = io.StringIO()
        with mock.patch.dict(os.environ, environment, clear=False), \
             contextlib.redirect_stdout(command_output):
          self.assertEqual(0, backend.dispatch(args))
        return json.loads(command_output.getvalue())

      self.assertEqual(3, len(cached(["teams", "cache", "chat", "list"])))
      self.assertGreaterEqual(
          len(cached([
              "teams", "cache", "chat", "message", "list",
              "--chatId", "mock-chat-ada", "--limit", "1000000",
          ])),
          3,
      )
      self.assertEqual(2, len(cached(["teams", "cache", "team", "list"])))
      self.assertEqual(
          2,
          len(cached([
              "teams", "cache", "channel", "list",
              "--teamId", "mock-team-engineering",
          ])),
      )
      self.assertEqual(
          1,
          len(cached([
              "teams", "cache", "channel", "message", "list",
              "--teamId", "mock-team-engineering",
              "--channelId", "mock-channel-general",
              "--limit", "1000000",
          ])),
      )
      self.assertEqual(
          2,
          len(cached([
              "teams", "cache", "channel", "reply", "list",
              "--teamId", "mock-team-engineering",
              "--channelId", "mock-channel-general",
              "--messageId", "mock-channel-general-1",
              "--limit", "1000000",
          ])),
      )


if __name__ == "__main__":
  unittest.main()
