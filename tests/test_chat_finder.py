"""Read-only chat discovery, independent of recents, with no live account."""
import copy
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin"))
import teams4e_graph as backend
from teams4e_mock import MockTenant


class ChatFinderTests(unittest.TestCase):
  def test_all_pages_including_old_chat_not_only_first_300(self):
    chats = [{"id": str(i), "topic": "Other", "members": []} for i in range(351)]
    chats[-1].update(topic="Launch plan", chatType="group", members=[
        {"displayName": "Ada Lovelace", "email": "ada@example.test"}])
    pages = [{"value": chats[i:i + 50],
              **({"@odata.nextLink": f"https://graph.microsoft.com/v1.0/page/{i + 50}"}
                 if i + 50 < len(chats) else {})} for i in range(0, len(chats), 50)]
    with mock.patch.object(backend, "graph_json", side_effect=pages) as request:
      result = backend.find_chats("launch ADA@example.test", "token")
    self.assertEqual(["350"], [chat["id"] for chat in result["chats"]])
    self.assertEqual(351, result["scanned"])
    self.assertEqual(8, request.call_count)
    self.assertTrue(result["complete"])
    query = parse_qs(urlsplit(request.call_args_list[0].args[0]).query)
    self.assertEqual(["members"], query["$expand"])
    self.assertNotIn("$filter", query)
    self.assertTrue(all("method" not in call.kwargs for call in request.call_args_list))

  def test_members_beyond_expansion_cap_are_searched(self):
    chat = {"id": "large", "members": [{"displayName": "Other"}] * 25}
    with mock.patch.object(backend, "graph_json", side_effect=[
        {"value": [chat]}, {"value": chat["members"],
                            "@odata.nextLink": "https://graph.microsoft.com/v1.0/more-members"},
        {"value": [{"displayName": "Grace Hopper"}]},
    ]) as request:
      result = backend.find_chats("grace", "token")
    self.assertEqual("large", result["chats"][0]["id"])
    self.assertEqual(26, len(result["chats"][0]["members"]))
    self.assertEqual("/chats/large/members", request.call_args_list[1].args[0])

  def test_known_topic_match_does_not_fetch_large_membership(self):
    chat = {"id": "large", "topic": "R&D [v2]", "members": [{}] * 25}
    with mock.patch.object(backend, "graph_json", return_value={"value": [chat]}) as request:
      result = backend.find_chats("[V2] R&D", "token")
    self.assertEqual(1, request.call_count)
    self.assertFalse(result["chats"][0]["membersLoaded"])
    self.assertTrue(result["complete"])

  def test_failed_member_lookup_does_not_claim_exhaustive_results(self):
    with mock.patch.object(backend, "graph_json", side_effect=[
        {"value": [{"id": "missing"}, {"id": "known", "topic": "Ada", "members": []}]},
        backend.BackendError("403"),
    ]):
      result = backend.find_chats("ada", "token")
    self.assertEqual(["known"], [chat["id"] for chat in result["chats"]])
    self.assertFalse(result["complete"])
    self.assertEqual(1, result["memberErrors"])

  def test_blank_query_never_fetches(self):
    with mock.patch.object(backend, "graph_json") as request:
      with self.assertRaises(backend.BackendError):
        backend.find_chats("  ", "token")
    request.assert_not_called()

  def test_command_routes_to_finder_without_recents_limit(self):
    with mock.patch.object(backend, "mock_enabled", return_value=False), \
         mock.patch.object(backend, "ensure_graph_token", return_value="token"), \
         mock.patch.object(backend, "find_chats", return_value={"chats": []}) as find:
      result, output = backend.execute(["teams", "chat", "find", "--query", "ada", "--output", "json"])
    find.assert_called_once_with("ada", "token")
    self.assertEqual({"chats": []}, result)
    self.assertEqual("json", output)

  def test_name_requires_all_words_and_deduplicates_ids(self):
    chat = {"id": "match", "chatType": "meeting", "members": [
        {"displayName": "Ada"}, {"displayName": "Grace"}]}
    with mock.patch.object(backend, "graph_json", return_value={"value": [chat, chat]}):
      result = backend.find_chats("ada grace meeting", "token")
    self.assertEqual(1, len(result["chats"]))
    with mock.patch.object(backend, "graph_json", return_value={"value": [chat]}):
      self.assertEqual([], backend.find_chats("ada unknown", "token")["chats"])

  def test_mock_finds_chat_outside_recents_without_mutation(self):
    with tempfile.TemporaryDirectory() as directory:
      tenant = MockTenant(Path(directory) / "tenant.json")
      tenant.state["chats"].append({"id": "old", "topic": "Old project", "chatType": "group"})
      tenant.state["chatMembers"]["old"] = [{"displayName": "Ada", "email": "ada@example.test"}]
      before = copy.deepcopy(tenant.state)
      recents = tenant.execute(["teams", "chat", "list", "--metadataLimit", "1"])
      self.assertNotIn("old", [chat["id"] for chat in recents])
      result = tenant.execute(["teams", "chat", "find", "--query", "old ada"])
      self.assertEqual(["old"], [chat["id"] for chat in result["chats"]])
      self.assertEqual(before, tenant.state)
