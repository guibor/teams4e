#!/usr/bin/env python3
"""Write synthetic screenshot data using the real mock tenant schema."""
import copy
import datetime as dt
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin"))
from teams4e_mock import seed_state, _message

def build_state():
    state = seed_state()
    today = dt.datetime.now(dt.timezone.utc).replace(hour=9, minute=0, second=0, microsecond=0)
    stamp = lambda minutes: (today + dt.timedelta(minutes=minutes)).isoformat().replace("+00:00", "Z")
    people = state["users"]
    me, ada, grace, alan = people
    messages = [
        _message("demo-atlas-1", grace, "Morning! Can we agree on the release checklist before the review?", stamp(0)),
        _message("demo-atlas-2", me, "Yes. The retry fix is merged; I am checking the remaining edge cases.", stamp(3)),
        _message("demo-atlas-3", alan,
                 "<p><strong>Latest checks</strong></p><table><tr><th>Area</th><th>Status</th></tr>"
                 "<tr><td>Pagination</td><td>Passing</td></tr><tr><td>Offline cache</td><td>Passing</td></tr>"
                 "<tr><td>Keyboard navigation</td><td>Review today</td></tr></table>"
                 "<p>The <a href='https://example.test/review'>review notes</a> include the test cases.</p>",
                 stamp(7), content_type="html"),
        _message("demo-atlas-4", ada, "I can review keyboard navigation. Please keep the unsent draft when switching chats.", stamp(12)),
        _message("demo-atlas-5", me, "Agreed. I will add a regression test for that and update the notes.", stamp(17)),
        _message("demo-atlas-6", grace, "Thanks. Let's cover the remaining questions in the architecture review tomorrow.", stamp(22)),
    ]
    atlas = state["chats"][1]
    atlas.update(lastUpdatedDateTime=stamp(22), lastMessagePreview=copy.deepcopy(messages[-1]))
    atlas["viewpoint"]["lastMessageReadDateTime"] = stamp(3)
    state["chatMessages"][atlas["id"]] = messages
    direct = state["chats"][0]
    direct_message = _message("demo-ada-1", ada, "The navigation tests pass. Shall we review the shortcuts together?", stamp(20))
    state["chatMessages"][direct["id"]] = [direct_message]
    direct.update(lastUpdatedDateTime=stamp(20), lastMessagePreview=copy.deepcopy(direct_message))
    for i, (title, body) in enumerate([
        ("Release readiness", "The checklist is updated. Two items need review."),
        ("Documentation", "Added a short setup guide and examples."),
        ("Accessibility review", "Keyboard-only navigation is ready for another pass."),
        ("API integration", "The mock covers pagination and expired-token recovery."),
        ("Engineering", "Today's review notes are ready."),
        ("Design discussion", "Let's keep the reading pane quiet and predictable."),
        ("Testing", "The offline fixtures are ready for review."),
        ("Platform", "No changes needed to the rollout plan."),
        ("Release notes", "The draft is ready for comments."),
        ("Developer experience", "The setup walkthrough now includes Linux."),
        ("Bug triage", "Two fixes landed; one report needs reproduction steps."),
        ("Onboarding", "Welcome! The getting-started notes are in the channel."),
    ]):
        chat = copy.deepcopy(atlas)
        chat_id = f"demo-chat-{i}"
        message = _message(f"demo-message-{i}", people[1 + i % 3], body, stamp(18 - i * 2))
        chat.update(id=chat_id, topic=title, lastUpdatedDateTime=message["createdDateTime"],
                    lastMessagePreview=copy.deepcopy(message),
                    webUrl=f"https://teams.microsoft.com/mock/chat/demo-{i}")
        chat["viewpoint"]["lastMessageReadDateTime"] = stamp(-60 if i % 2 == 0 else 30)
        state["chats"].append(chat)
        state["chatMembers"][chat_id] = copy.deepcopy(state["chatMembers"]["mock-chat-atlas"])
        state["chatMessages"][chat_id] = [message]
    original = copy.deepcopy(state["chats"][2])
    event = copy.deepcopy(state["meetingEvents"]["mock-chat-future-meeting"])
    for i, (title, location) in enumerate([
        ("Architecture review", "Video room 4"),
        ("Release checkpoint", "Online"),
        ("Design walkthrough", "Studio room 2"),
    ]):
        chat_id = "mock-chat-future-meeting" if i == 0 else f"demo-meeting-{i}"
        chat = copy.deepcopy(original)
        meeting = copy.deepcopy(event)
        start = today + dt.timedelta(days=1, hours=i * 2)
        meeting.update(id=f"demo-event-{i}", subject=title,
                       start={"dateTime": start.strftime("%Y-%m-%dT%H:%M:%S"), "timeZone": "UTC"},
                       end={"dateTime": (start + dt.timedelta(minutes=45)).strftime("%Y-%m-%dT%H:%M:%S"), "timeZone": "UTC"},
                       location={"displayName": location},
                       responseStatus={"response": "notResponded" if i == 1 else "accepted"})
        meeting["locations"] = [meeting["location"]]
        chat.update(id=chat_id, topic=title, createdDateTime=stamp(-90), lastUpdatedDateTime=stamp(-30))
        chat["onlineMeetingInfo"]["calendarEventId"] = meeting["id"]
        if i == 0:
            state["chats"][2] = chat
        else:
            state["chats"].append(chat)
        state["chatMembers"][chat_id] = copy.deepcopy(state["chatMembers"]["mock-chat-future-meeting"])
        state["chatMessages"][chat_id] = []
        state["meetingEvents"][chat_id] = meeting
    return state

if __name__ == "__main__":
    target = Path(sys.argv[1])
    target.parent.mkdir(parents=True, exist_ok=True)
    # Refuse to overwrite an existing mock session or any user's data.
    with target.open("x") as output:
        json.dump(build_state(), output, indent=2)
    target.chmod(0o600)
