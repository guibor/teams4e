"""Screenshot meetings must represent separate calendar identities."""
import runpy
from pathlib import Path
import unittest


class DemoSeedTests(unittest.TestCase):
    def test_distinct_meetings_have_distinct_matching_keys(self):
        seed = runpy.run_path(str(Path(__file__).resolve().parents[1]
                                 / "tools" / "seed-demo.py"))
        state = seed["build_state"]()
        events = state["meetingEvents"]
        chats = {chat["id"]: chat for chat in state["chats"]}
        urls = set()
        ids = set()
        for chat_id, event in events.items():
            url = event["onlineMeeting"]["joinUrl"]
            self.assertNotIn(url, urls)
            self.assertNotIn(event["id"], ids)
            urls.add(url)
            ids.add(event["id"])
            info = chats[chat_id]["onlineMeetingInfo"]
            self.assertEqual(url, info["joinWebUrl"])
            self.assertEqual(event["id"], info["calendarEventId"])


if __name__ == "__main__":
    unittest.main()
