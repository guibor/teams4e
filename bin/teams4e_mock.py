# SPDX-License-Identifier: GPL-3.0-or-later
"""Persistent local Microsoft Teams mock implementing the production CLI contract."""

from __future__ import annotations

import copy
import json
import mimetypes
import os
import shutil
import tempfile
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from teams4e_cache import TeamsCache


def mock_enabled() -> bool:
  """Return whether the backend should use the local mock tenant."""
  return os.environ.get("TEAMS4E_MOCK", "").casefold() in {
      "1",
      "true",
      "yes",
      "on",
  }


def mock_delay() -> None:
  """Apply the bounded artificial request delay configured for local tests."""
  raw = os.environ.get("TEAMS4E_MOCK_DELAY_MS", "0")
  try:
    milliseconds = max(0.0, min(float(raw), 10_000.0))
  except ValueError:
    milliseconds = 0.0
  if milliseconds:
    time.sleep(milliseconds / 1000.0)


def default_state_path() -> Path:
  configured = os.environ.get("TEAMS4E_MOCK_STATE")
  if configured:
    return Path(configured).expanduser()
  root = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
  return root / "teams4e" / "mock-tenant.json"


def now_iso() -> str:
  return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace(
      "+00:00", "Z"
  )


def option(
    args: list[str], name: str, *, required: bool = True
) -> str | None:
  try:
    value = args[args.index(name) + 1]
  except (ValueError, IndexError):
    if required:
      raise ValueError(f"Missing required option {name}")
    return None
  if required and not value:
    raise ValueError(f"Missing required option {name}")
  return value


def options(args: list[str], name: str) -> list[str]:
  values: list[str] = []
  index = 0
  while index < len(args):
    if args[index] == name and index + 1 < len(args):
      values.append(args[index + 1])
      index += 2
    else:
      index += 1
  return values


def _identity(user: dict[str, Any]) -> dict[str, Any]:
  return {
      "user": {
          "id": user["id"],
          "displayName": user["displayName"],
          "userIdentityType": "aadUser",
      }
  }


def _message(
    message_id: str,
    user: dict[str, Any],
    body: str,
    created: str,
    *,
    content_type: str = "text",
    web_url: str | None = None,
    reactions: list[dict[str, Any]] | None = None,
    attachments: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
  return {
      "id": message_id,
      "replyToId": None,
      "etag": f'\"{message_id}\"',
      "messageType": "message",
      "createdDateTime": created,
      "lastModifiedDateTime": created,
      "lastEditedDateTime": None,
      "deletedDateTime": None,
      "subject": None,
      "summary": None,
      "importance": "normal",
      "locale": "en-us",
      "webUrl": web_url or f"https://teams.microsoft.com/mock/{message_id}",
      "from": _identity(user),
      "body": {"contentType": content_type, "content": body},
      "attachments": attachments or [],
      "mentions": [],
      "reactions": reactions or [],
  }


def _message_reference(source: dict[str, Any]) -> dict[str, Any]:
  """Return the quoted-reference shape produced by Graph replyWithQuote."""
  sender = source.get("from", {}).get("user", {})
  body = source.get("body", {})
  content = {
      "messageId": source.get("id"),
      "messagePreview": body.get("content", ""),
      "messageSender": {
          "application": None,
          "device": None,
          "user": {
              "userIdentityType": "aadUser",
              "id": sender.get("id", ""),
              "displayName": sender.get("displayName", "Teams"),
          },
      },
  }
  return {
      "id": str(source.get("id", "quoted-message")),
      "contentType": "messageReference",
      "content": json.dumps(content, ensure_ascii=False, separators=(",", ":")),
      "contentUrl": None,
      "name": None,
      "thumbnailUrl": None,
      "teamsAppId": None,
  }


def seed_state() -> dict[str, Any]:
  me = {
      "id": "mock-user-current",
      "displayName": "Example User",
      "mail": "user@example.test",
      "userPrincipalName": "user@example.test",
      "jobTitle": "Reader and Builder",
      "officeLocation": "Local Test Tenant",
      "presence": {"availability": "Available", "activity": "Available"},
  }
  ada = {
      "id": "mock-user-ada",
      "displayName": "Ada Lovelace",
      "mail": "ada@example.test",
      "userPrincipalName": "ada@example.test",
      "jobTitle": "Systems Engineer",
      "officeLocation": "London",
      "presence": {"availability": "Busy", "activity": "InACall"},
  }
  grace = {
      "id": "mock-user-grace",
      "displayName": "Grace Hopper",
      "mail": "grace@example.test",
      "userPrincipalName": "grace@example.test",
      "jobTitle": "Principal Engineer",
      "officeLocation": "New York",
      "presence": {"availability": "Away", "activity": "Away"},
  }
  alan = {
      "id": "mock-user-alan",
      "displayName": "Alan Turing",
      "mail": "alan@example.test",
      "userPrincipalName": "alan@example.test",
      "jobTitle": "Research Scientist",
      "officeLocation": "Manchester",
      "presence": {"availability": "Available", "activity": "Available"},
  }
  users = [me, ada, grace, alan]
  reactions = [
      {
          "reactionType": "like",
          "createdDateTime": "2026-08-01T08:18:00Z",
          "user": _identity(me),
      }
  ]
  chat_ada_messages = [
      _message(
          "mock-chat-ada-1",
          ada,
          "<p>Hello there. The <strong>mock tenant</strong> is ready.</p>",
          "2026-08-01T08:15:00Z",
          content_type="html",
          reactions=reactions,
      ),
      _message(
          "mock-chat-ada-2",
          me,
          "Good. I will test this without changing server read state.",
          "2026-08-01T08:20:00Z",
      ),
      _message(
          "mock-chat-ada-3",
          ada,
          "Try search, reactions, editing, attachments, and the action queue.",
          "2026-08-02T06:40:00Z",
      ),
  ]
  atlas_messages = [
      _message(
          "mock-chat-atlas-1",
          grace,
          "The Atlas review starts at 10:00. Please read the channel thread.",
          "2026-08-02T07:00:00Z",
      ),
      _message(
          "mock-chat-atlas-2",
          alan,
          "I added notes on the paging and retry model.",
          "2026-08-02T07:12:00Z",
      ),
  ]
  chats = [
      {
          "id": "mock-chat-ada",
          "topic": None,
          "createdDateTime": "2026-07-15T10:00:00Z",
          "lastUpdatedDateTime": "2026-08-02T06:40:00Z",
          "chatType": "oneOnOne",
          "webUrl": "https://teams.microsoft.com/mock/chat/ada",
          "viewpoint": {"lastMessageReadDateTime": "2026-08-01T08:20:00Z"},
          "lastMessagePreview": copy.deepcopy(chat_ada_messages[-1]),
      },
      {
          "id": "mock-chat-atlas",
          "topic": "Project Atlas",
          "createdDateTime": "2026-07-20T10:00:00Z",
          "lastUpdatedDateTime": "2026-08-02T07:12:00Z",
          "chatType": "group",
          "webUrl": "https://teams.microsoft.com/mock/chat/atlas",
          "viewpoint": {"lastMessageReadDateTime": "2026-08-02T07:12:00Z"},
          "lastMessagePreview": copy.deepcopy(atlas_messages[-1]),
      },
      {
          "id": "mock-chat-future-meeting",
          "topic": "Architecture review",
          "createdDateTime": "2026-08-04T09:00:00Z",
          "lastUpdatedDateTime": "2026-08-05T08:00:00Z",
          "chatType": "meeting",
          "webUrl": "https://teams.microsoft.com/mock/chat/architecture-review",
          "viewpoint": {
              "lastMessageReadDateTime": "2026-08-05T08:00:00Z",
              "isHidden": False,
          },
          "onlineMeetingInfo": {
              "calendarEventId": "mock-event-architecture-review",
              "joinWebUrl": "https://teams.microsoft.com/mock/meeting/architecture-review",
              "organizer": _identity(grace),
          },
          "lastMessagePreview": None,
      },
  ]
  general_root = _message(
      "mock-channel-general-1",
      grace,
      "<p><strong>Release thread:</strong> verify the native Teams workflow.</p>",
      "2026-08-01T09:00:00Z",
      content_type="html",
  )
  general_root["subject"] = "Native client release"
  general_root["replies"] = []
  return {
      "version": 1,
      "tenant": {
          "id": "mock-tenant-local",
          "displayName": "Local Teams Mock",
      },
      "profile": me,
      "users": users,
      "chats": chats,
      "chatMembers": {
          "mock-chat-ada": [
              _member("mock-member-current-ada", me),
              _member("mock-member-ada", ada),
          ],
          "mock-chat-atlas": [
              _member("mock-member-current-atlas", me),
              _member("mock-member-grace", grace),
              _member("mock-member-alan", alan),
          ],
          "mock-chat-future-meeting": [
              _member("mock-member-current-meeting", me),
              _member("mock-member-grace-meeting", grace),
              _member("mock-member-ada-meeting", ada),
          ],
      },
      "chatMessages": {
          "mock-chat-ada": chat_ada_messages,
          "mock-chat-atlas": atlas_messages,
          "mock-chat-future-meeting": [],
      },
      "meetingEvents": {
          "mock-chat-future-meeting": {
              "id": "mock-event-architecture-review",
              "subject": "Architecture review",
              "start": {"dateTime": "2026-08-10T07:30:00", "timeZone": "UTC"},
              "end": {"dateTime": "2026-08-10T08:15:00", "timeZone": "UTC"},
              "isAllDay": False,
              "isCancelled": False,
              "showAs": "busy",
              "responseStatus": {"response": "accepted"},
              "allowNewTimeProposals": True,
              "isOrganizer": False,
              "responseRequested": True,
              "type": "singleInstance",
              "location": {"displayName": "Video room 4"},
              "locations": [{"displayName": "Video room 4"}],
              "organizer": {"emailAddress": {
                  "name": grace["displayName"],
                  "address": grace["mail"],
              }},
              "attendees": [
                  {
                      "emailAddress": {
                          "name": me["displayName"],
                          "address": me["mail"],
                      },
                      "type": "required",
                      "status": {"response": "accepted"},
                  },
                  {
                      "emailAddress": {
                          "name": ada["displayName"],
                          "address": ada["mail"],
                      },
                      "type": "required",
                      "status": {"response": "accepted"},
                  },
              ],
              "onlineMeeting": {
                  "joinUrl": "https://teams.microsoft.com/mock/meeting/architecture-review"
              },
          }
      },
      "meetingTranscripts": {
          "mock-chat-future-meeting": {
              "id": "mock-transcript-architecture-review",
              "createdDateTime": "2026-08-05T08:45:00Z",
              "endDateTime": "2026-08-05T09:30:00Z",
              "content": (
                  "WEBVTT\n\n00:00:00.000 --> 00:00:04.000\n"
                  "<v Grace Hopper>We should keep one message cache.</v>\n\n"
                  "00:00:04.000 --> 00:00:08.000\n"
                  "<v Example User>Agreed. Graph remains authoritative.</v>\n"
              ),
          }
      },
      "teams": [
          {
              "id": "mock-team-engineering",
              "displayName": "Engineering",
              "description": "Mock engineering team",
              "visibility": "private",
              "webUrl": "https://teams.microsoft.com/mock/team/engineering",
          },
          {
              "id": "mock-team-research",
              "displayName": "Research",
              "description": "Mock research team",
              "visibility": "private",
              "webUrl": "https://teams.microsoft.com/mock/team/research",
          },
      ],
      "channels": {
          "mock-team-engineering": [
              {
                  "id": "mock-channel-general",
                  "displayName": "General",
                  "description": "Engineering announcements and threads",
                  "membershipType": "standard",
                  "webUrl": "https://teams.microsoft.com/mock/channel/general",
              },
              {
                  "id": "mock-channel-client",
                  "displayName": "teams-client",
                  "description": "Native client implementation",
                  "membershipType": "standard",
                  "webUrl": "https://teams.microsoft.com/mock/channel/client",
              },
          ],
          "mock-team-research": [
              {
                  "id": "mock-channel-reading",
                  "displayName": "reading",
                  "description": "Research and reading notes",
                  "membershipType": "standard",
                  "webUrl": "https://teams.microsoft.com/mock/channel/reading",
              }
          ],
      },
      "channelMessages": {
          "mock-team-engineering/mock-channel-general": [general_root],
          "mock-team-engineering/mock-channel-client": [
              _message(
                  "mock-channel-client-1",
                  alan,
                  "Cache search should continue to work while offline.",
                  "2026-08-02T05:30:00Z",
              )
          ],
          "mock-team-research/mock-channel-reading": [
              _message(
                  "mock-channel-reading-1",
                  ada,
                  "The thread view should preserve position after refresh.",
                  "2026-08-02T05:45:00Z",
              )
          ],
      },
      "channelReplies": {
          "mock-team-engineering/mock-channel-general/mock-channel-general-1": [
              _reply(
                  "mock-channel-general-reply-1",
                  "mock-channel-general-1",
                  alan,
                  "The mock covers the production command contract.",
                  "2026-08-01T09:05:00Z",
              ),
              _reply(
                  "mock-channel-general-reply-2",
                  "mock-channel-general-1",
                  me,
                  "I will validate every mutation locally.",
                  "2026-08-01T09:10:00Z",
              ),
          ]
      },
  }


def _member(member_id: str, user: dict[str, Any]) -> dict[str, Any]:
  return {
      "@odata.type": "#microsoft.graph.aadUserConversationMember",
      "id": member_id,
      "roles": ["owner"],
      "displayName": user["displayName"],
      "userId": user["id"],
      "email": user["mail"],
      "tenantId": "mock-tenant-local",
  }


def _reply(
    message_id: str,
    root_id: str,
    user: dict[str, Any],
    body: str,
    created: str,
) -> dict[str, Any]:
  result = _message(message_id, user, body, created)
  result["replyToId"] = root_id
  return result


class MockTenant:
  """Stateful local stand-in for Graph, suitable for UI and mutation tests."""

  def __init__(self, path: Path | None = None) -> None:
    self.path = (path or default_state_path()).expanduser()
    self.path.parent.mkdir(parents=True, exist_ok=True)
    try:
      self.path.parent.chmod(0o700)
    except OSError:
      pass
    self.state = self._load_or_seed()

  @property
  def attachments_dir(self) -> Path:
    return self.path.with_suffix(".attachments")

  def _load_or_seed(self) -> dict[str, Any]:
    if self.path.exists():
      try:
        value = json.loads(self.path.read_text(encoding="utf-8"))
        if isinstance(value, dict) and value.get("version") == 1:
          return value
      except (OSError, json.JSONDecodeError):
        pass
    value = seed_state()
    self._write(value)
    return value

  def _write(self, value: dict[str, Any] | None = None) -> None:
    if value is not None:
      self.state = value
    temporary_fd, temporary_name = tempfile.mkstemp(
        prefix=".mock-tenant-", dir=self.path.parent
    )
    try:
      with os.fdopen(temporary_fd, "w", encoding="utf-8") as stream:
        json.dump(self.state, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
      os.chmod(temporary_name, 0o600)
      os.replace(temporary_name, self.path)
    finally:
      if os.path.exists(temporary_name):
        os.unlink(temporary_name)

  def reset(self) -> dict[str, Any]:
    if self.attachments_dir.exists():
      shutil.rmtree(self.attachments_dir)
    self._write(seed_state())
    return self.info()

  def info(self) -> dict[str, Any]:
    return {
        "enabled": True,
        "stateFile": str(self.path),
        "connectedAs": self.state["profile"]["mail"],
        "chats": len(self.state["chats"]),
        "teams": len(self.state["teams"]),
    }

  def status(self) -> dict[str, Any]:
    profile = self.state["profile"]
    return {
        "connectionName": "Local mock tenant",
        "connectedAs": profile["mail"],
        "displayName": profile["displayName"],
        "userId": profile["id"],
        "authType": "MockTenant",
        "appTenant": self.state["tenant"]["id"],
        "appId": "none",
        "graphTokenStatus": "mock",
        "graphExpiresAt": None,
        "credentialFile": None,
        "mockStateFile": str(self.path),
    }

  def _chat(self, chat_id: str) -> dict[str, Any]:
    for chat in self.state["chats"]:
      if chat.get("id") == chat_id:
        return chat
    raise ValueError(f"Unknown mock chat: {chat_id}")

  def _meeting_event(self, event_id: str) -> dict[str, Any]:
    for event in self.state.get("meetingEvents", {}).values():
      if isinstance(event, dict) and event.get("id") == event_id:
        return event
    raise ValueError(f"Unknown mock meeting event: {event_id}")

  @staticmethod
  def _meeting_datetime(value: str) -> datetime:
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    parsed = datetime.fromisoformat(normalized)
    if parsed.tzinfo is None:
      parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)

  @staticmethod
  def _meeting_date_time(value: datetime) -> dict[str, str]:
    return {
        "dateTime": value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S"),
        "timeZone": "UTC",
    }

  def _meeting_time_suggestions(
      self, args: list[str], *, validate_proposal: bool = True
  ) -> dict[str, Any]:
    event = self._meeting_event(str(option(args, "--eventId")))
    if validate_proposal and event.get("isCancelled"):
      raise ValueError("Cannot propose a new time for a cancelled mock meeting")
    if validate_proposal and event.get("isOrganizer"):
      raise ValueError("You organize this mock meeting")
    if validate_proposal and event.get("allowNewTimeProposals") is False:
      raise ValueError("The organizer does not allow new time proposals")
    start = self._meeting_datetime(str(event["start"]["dateTime"]))
    end = self._meeting_datetime(str(event["end"]["dateTime"]))
    duration = end - start
    search_start = self._meeting_datetime(str(option(args, "--searchStart")))
    search_end = self._meeting_datetime(str(option(args, "--searchEnd")))
    if search_end <= search_start:
      raise ValueError("Mock meeting suggestion search must end after it starts")
    maximum = max(1, int(option(args, "--maxCandidates", required=False) or 8))
    minimum = max(
        0, int(option(args, "--minimumConfidence", required=False) or 50)
    )
    activity_domain = option(args, "--activityDomain", required=False) or "work"
    if activity_domain not in {"work", "personal", "unrestricted"}:
      raise ValueError(f"Unsupported mock meeting activity domain: {activity_domain}")
    contacts = [event.get("organizer"), *event.get("attendees", [])]
    self_address = str(self.state["profile"].get("mail") or "").casefold()
    attendees = []
    seen: set[str] = set()
    for contact in contacts:
      email = contact.get("emailAddress", {}) if isinstance(contact, dict) else {}
      address = str(email.get("address") or "")
      if not address or address.casefold() == self_address or address.casefold() in seen:
        continue
      seen.add(address.casefold())
      attendees.append(copy.deepcopy(email))

    candidate_starts = [start + timedelta(days=1), start + timedelta(days=2, hours=1)]
    suggestions = []
    for index, candidate_start in enumerate(candidate_starts):
      candidate_end = candidate_start + duration
      if candidate_start < search_start or candidate_end > search_end:
        continue
      confidence = 100 if index == 0 else 50
      if confidence < minimum:
        continue
      availability = []
      for attendee_index, email in enumerate(attendees):
        state = "busy" if index == 1 and attendee_index == len(attendees) - 1 else "free"
        availability.append({
            "availability": state,
            "attendee": {"emailAddress": email},
        })
      suggestions.append({
          "confidence": confidence,
          "order": index + 1,
          "organizerAvailability": "free",
          "suggestionReason": (
              "Everyone is available in the mock tenant."
              if index == 0
              else "One attendee is busy in the mock tenant."
          ),
          "attendeeAvailability": availability,
          "meetingTimeSlot": {
              "start": self._meeting_date_time(candidate_start),
              "end": self._meeting_date_time(candidate_end),
          },
      })
      if len(suggestions) >= maximum:
        break
    return {
        "event": copy.deepcopy(event),
        "suggestions": suggestions,
        "emptySuggestionsReason": "" if suggestions else "No mock slots in range",
        "search": {
            "start": self._meeting_date_time(search_start),
            "end": self._meeting_date_time(search_end),
            "activityDomain": activity_domain,
        },
    }

  def _meeting_availability(self, args: list[str]) -> dict[str, Any]:
    event = self._meeting_event(str(option(args, "--eventId")))
    suggestions = self._meeting_time_suggestions(
        args, validate_proposal=False
    )
    profile = copy.deepcopy(self.state["profile"])
    self_address = str(profile.get("mail") or "")
    contacts = [
        {
            "email": self_address,
            "name": profile.get("displayName") or self_address,
            "type": "required",
            "isSelf": True,
            "isOrganizer": bool(event.get("isOrganizer")),
            "response": event.get("responseStatus", {}).get("response"),
        }
    ]
    seen = {self_address.casefold()}
    organizer = event.get("organizer")
    attendees = event.get("attendees", [])
    for contact, is_organizer in [
        (organizer, True),
        *((attendee, False) for attendee in attendees),
    ]:
      email = contact.get("emailAddress", {}) if isinstance(contact, dict) else {}
      address = str(email.get("address") or "")
      if not address or address.casefold() in seen:
        continue
      seen.add(address.casefold())
      contacts.append({
          "email": address,
          "name": email.get("name") or address,
          "type": contact.get("type") or "required",
          "isSelf": False,
          "isOrganizer": is_organizer,
          "response": contact.get("status", {}).get("response"),
      })

    event_start = self._meeting_datetime(str(event["start"]["dateTime"]))
    event_end = self._meeting_datetime(str(event["end"]["dateTime"]))
    candidate_two = event_start + timedelta(days=2, hours=1)
    event_item = {
        "isPrivate": False,
        "status": "busy",
        "subject": event.get("subject") or "Architecture review",
        "location": event.get("location", {}).get("displayName"),
        "start": self._meeting_date_time(event_start),
        "end": self._meeting_date_time(event_end),
    }
    schedules = []
    for index, participant in enumerate(contacts):
      items = [copy.deepcopy(event_item)]
      if participant["isSelf"]:
        focus_start = event_start + timedelta(days=1, hours=-2)
        items.append({
            "isPrivate": False,
            "status": "busy",
            "subject": "Focus block",
            "location": "Home office",
            "start": self._meeting_date_time(focus_start),
            "end": self._meeting_date_time(focus_start + timedelta(hours=1)),
        })
      elif index == len(contacts) - 1:
        items.append({
            "isPrivate": False,
            "status": "busy",
            "subject": "Customer review",
            "location": "Room 12",
            "start": self._meeting_date_time(candidate_two),
            "end": self._meeting_date_time(candidate_two + timedelta(hours=1)),
        })
      schedules.append({
          "scheduleId": participant["email"],
          "availabilityView": "",
          "scheduleItems": items,
          "workingHours": {
              "daysOfWeek": [
                  "monday", "tuesday", "wednesday", "thursday", "friday"
              ],
              "startTime": "08:00:00",
              "endTime": "17:00:00",
              "timeZone": {"name": "UTC"},
          },
      })
    reason = None
    if event.get("isCancelled"):
      reason = "This meeting is cancelled"
    elif event.get("isOrganizer"):
      reason = "You organize this meeting; use the calendar event to reschedule"
    elif event.get("allowNewTimeProposals") is False:
      reason = "The organizer does not allow new time proposals"
    return {
        **suggestions,
        "profile": profile,
        "participants": contacts,
        "schedules": schedules,
        "scheduleError": None,
        "proposalAllowed": reason is None,
        "proposalUnavailableReason": reason,
    }

  def _respond_to_meeting(self, args: list[str]) -> dict[str, Any]:
    event = self._meeting_event(str(option(args, "--eventId")))
    response = str(option(args, "--response"))
    if response not in {"accepted", "tentativelyAccepted", "declined"}:
      raise ValueError(f"Unsupported mock meeting response: {response}")
    if event.get("isCancelled"):
      raise ValueError("Cannot respond to a cancelled mock meeting")
    if event.get("isOrganizer"):
      raise ValueError("The mock meeting organizer cannot RSVP as an attendee")
    response_time = now_iso()
    event["responseStatus"] = {
        "response": response,
        "time": response_time,
    }
    self_address = str(self.state["profile"].get("mail") or "").casefold()
    for attendee in event.get("attendees", []):
      address = str(attendee.get("emailAddress", {}).get("address") or "")
      if address.casefold() == self_address:
        attendee["status"] = {
            "response": response,
            "time": response_time,
        }
        break
    self._write()
    return {
        "status": "responded",
        "response": response,
        "event": copy.deepcopy(event),
    }

  def _propose_meeting_time(self, args: list[str]) -> dict[str, Any]:
    event_id = str(option(args, "--eventId"))
    event = self._meeting_event(event_id)
    if event.get("isCancelled"):
      raise ValueError("Cannot propose a new time for a cancelled mock meeting")
    if event.get("isOrganizer"):
      raise ValueError("You organize this mock meeting")
    if event.get("allowNewTimeProposals") is False:
      raise ValueError("The organizer does not allow new time proposals")
    start = self._meeting_datetime(str(option(args, "--start")))
    end = self._meeting_datetime(str(option(args, "--end")))
    if end <= start:
      raise ValueError("Proposed meeting end must be after its start")
    proposal = {
        "start": self._meeting_date_time(start),
        "end": self._meeting_date_time(end),
    }
    response_time = now_iso()
    event["responseStatus"] = {
        "response": "tentativelyAccepted",
        "time": response_time,
    }
    self_address = str(self.state["profile"].get("mail") or "").casefold()
    for attendee in event.get("attendees", []):
      address = str(attendee.get("emailAddress", {}).get("address") or "")
      if address.casefold() == self_address:
        attendee["status"] = {
            "response": "tentativelyAccepted",
            "time": response_time,
        }
        attendee["proposedNewTime"] = copy.deepcopy(proposal)
        break
    self._write()
    return {
        "status": "proposed",
        "eventId": event_id,
        "event": copy.deepcopy(event),
        "proposal": proposal,
    }

  def _user(self, user_id_or_email: str) -> dict[str, Any]:
    wanted = user_id_or_email.casefold()
    for user in self.state["users"]:
      if wanted in {
          str(user.get("id", "")).casefold(),
          str(user.get("mail", "")).casefold(),
          str(user.get("userPrincipalName", "")).casefold(),
      }:
        return user
    raise ValueError(f"Unknown mock user: {user_id_or_email}")

  def _message_target(
      self, args: list[str]
  ) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    scope = str(option(args, "--scope"))
    message_id = str(option(args, "--messageId"))
    if scope == "chat":
      chat_id = str(option(args, "--chatId"))
      messages = self.state["chatMessages"].get(chat_id, [])
    elif scope == "channel":
      team_id = str(option(args, "--teamId"))
      channel_id = str(option(args, "--channelId"))
      root_id = option(args, "--rootMessageId", required=False)
      if root_id:
        key = f"{team_id}/{channel_id}/{root_id}"
        messages = self.state["channelReplies"].get(key, [])
      else:
        key = f"{team_id}/{channel_id}"
        messages = self.state["channelMessages"].get(key, [])
    else:
      raise ValueError("--scope must be chat or channel")
    for message in messages:
      if message.get("id") == message_id:
        return messages, message
    raise ValueError(f"Unknown mock message: {message_id}")

  def _copy_attachments(self, paths: list[str]) -> list[dict[str, Any]]:
    attachments: list[dict[str, Any]] = []
    if paths:
      self.attachments_dir.mkdir(parents=True, exist_ok=True)
      try:
        self.attachments_dir.chmod(0o700)
      except OSError:
        pass
    for path_text in paths:
      path = Path(path_text).expanduser().resolve()
      if not path.is_file():
        raise ValueError(f"Attachment is not a file: {path}")
      destination = self.attachments_dir / f"{uuid.uuid4().hex[:8]}-{path.name}"
      shutil.copy2(path, destination)
      try:
        destination.chmod(0o600)
      except OSError:
        pass
      attachments.append(
          {
              "id": f"mock-attachment-{uuid.uuid4().hex}",
              "contentType": "reference",
              "contentUrl": destination.as_uri(),
              "name": path.name,
              "thumbnailUrl": None,
              "content": None,
              "teamsAppId": None,
              "mimeType": mimetypes.guess_type(path.name)[0]
              or "application/octet-stream",
          }
      )
    return attachments

  def _new_message(
      self,
      body: str,
      *,
      attachments: list[str] | None = None,
      reply_to: str | None = None,
      content_type: str = "text",
      mention_specs: list[str] | None = None,
  ) -> dict[str, Any]:
    message = _message(
        f"mock-message-{uuid.uuid4().hex}",
        self.state["profile"],
        body,
        now_iso(),
        content_type=content_type,
        attachments=self._copy_attachments(attachments or []),
    )
    message["replyToId"] = reply_to
    for index, specification in enumerate(mention_specs or []):
      user_id, separator, display_name = specification.partition("|")
      if not separator:
        raise ValueError("Mention values must use USER-ID|DISPLAY-NAME")
      message["mentions"].append(
          {
              "id": index,
              "mentionText": display_name,
              "mentioned": {
                  "user": {
                      "id": user_id,
                      "displayName": display_name,
                      "userIdentityType": "aadUser",
                  }
              },
          }
      )
    return message

  def _send_chat(self, args: list[str]) -> dict[str, Any]:
    chat_id = option(args, "--chatId", required=False)
    emails = option(args, "--userEmails", required=False)
    if not chat_id and emails:
      wanted = {item.strip().casefold() for item in emails.split(",")}
      for candidate in self.state["chats"]:
        members = self.state["chatMembers"].get(candidate["id"], [])
        member_emails = {
            str(member.get("email", "")).casefold()
            for member in members
            if member.get("userId") != self.state["profile"]["id"]
        }
        if wanted == member_emails:
          chat_id = candidate["id"]
          break
    if not chat_id:
      raise ValueError("No matching mock chat")
    chat = self._chat(str(chat_id))
    reply_to = option(args, "--replyToId", required=False)
    message = self._new_message(
        str(option(args, "--message")),
        attachments=options(args, "--attachment"),
        reply_to=reply_to,
        content_type=option(args, "--contentType", required=False) or "text",
        mention_specs=options(args, "--mention"),
    )
    messages = self.state["chatMessages"].setdefault(str(chat_id), [])
    if reply_to:
      source = next(
          (candidate for candidate in messages if candidate.get("id") == reply_to),
          None,
      )
      if source is None:
        raise ValueError(f"Unknown mock reply target: {reply_to}")
      message["attachments"].insert(0, _message_reference(source))
    messages.append(message)
    chat["lastUpdatedDateTime"] = message["createdDateTime"]
    chat["lastMessagePreview"] = copy.deepcopy(message)
    self._write()
    return message

  def _send_channel(self, args: list[str]) -> dict[str, Any]:
    team_id = str(option(args, "--teamId"))
    channel_id = str(option(args, "--channelId"))
    reply_to = option(args, "--replyToId", required=False)
    message = self._new_message(
        str(option(args, "--message")),
        attachments=options(args, "--attachment"),
        reply_to=reply_to,
        content_type=option(args, "--contentType", required=False) or "text",
        mention_specs=options(args, "--mention"),
    )
    if reply_to:
      key = f"{team_id}/{channel_id}/{reply_to}"
      self.state["channelReplies"].setdefault(key, []).append(message)
    else:
      key = f"{team_id}/{channel_id}"
      self.state["channelMessages"].setdefault(key, []).append(message)
    self._write()
    return message

  def _react(self, args: list[str], enabled: bool) -> dict[str, Any]:
    _messages, message = self._message_target(args)
    reaction_type = str(option(args, "--reaction"))
    user_id = self.state["profile"]["id"]
    reactions = message.setdefault("reactions", [])
    reactions[:] = [
        reaction
        for reaction in reactions
        if not (
            reaction.get("reactionType") == reaction_type
            and reaction.get("user", {}).get("user", {}).get("id") == user_id
        )
    ]
    if enabled:
      reactions.append(
          {
              "reactionType": reaction_type,
              "createdDateTime": now_iso(),
              "user": _identity(self.state["profile"]),
          }
      )
    message["lastModifiedDateTime"] = now_iso()
    self._write()
    return message

  def _edit(self, args: list[str]) -> dict[str, Any]:
    _messages, message = self._message_target(args)
    sender_id = message.get("from", {}).get("user", {}).get("id")
    if sender_id != self.state["profile"]["id"]:
      raise ValueError("Mock tenant only permits editing your own message")
    timestamp = now_iso()
    message["body"] = {
        "contentType": "text",
        "content": str(option(args, "--message")),
    }
    message["lastEditedDateTime"] = timestamp
    message["lastModifiedDateTime"] = timestamp
    self._write()
    return message

  def _delete(self, args: list[str]) -> dict[str, Any]:
    _messages, message = self._message_target(args)
    sender_id = message.get("from", {}).get("user", {}).get("id")
    if sender_id != self.state["profile"]["id"]:
      raise ValueError("Mock tenant only permits deleting your own message")
    timestamp = now_iso()
    message["mockDeletedBody"] = copy.deepcopy(message.get("body"))
    message["deletedDateTime"] = timestamp
    message["lastModifiedDateTime"] = timestamp
    message["body"] = {"contentType": "text", "content": ""}
    self._write()
    return message

  def _restore(self, args: list[str]) -> dict[str, Any]:
    _messages, message = self._message_target(args)
    message["deletedDateTime"] = None
    message["lastModifiedDateTime"] = now_iso()
    message["body"] = message.pop(
        "mockDeletedBody",
        {"contentType": "text", "content": "[Restored mock message]"},
    )
    self._write()
    return message

  def _create_chat(self, args: list[str]) -> dict[str, Any]:
    requested = options(args, "--userId")
    requested.extend(
        item.strip()
        for item in str(option(args, "--userEmails", required=False) or "").split(",")
        if item.strip()
    )
    users = [self.state["profile"]]
    for identifier in requested:
      user = self._user(identifier)
      if user["id"] not in {candidate["id"] for candidate in users}:
        users.append(user)
    if len(users) < 2:
      raise ValueError("A new mock chat needs at least one other user")
    chat_type = "oneOnOne" if len(users) == 2 else "group"
    topic = option(args, "--topic", required=False)
    if chat_type == "oneOnOne":
      for chat in self.state["chats"]:
        if chat.get("chatType") != "oneOnOne":
          continue
        member_ids = {
            member["userId"]
            for member in self.state["chatMembers"].get(chat["id"], [])
        }
        if member_ids == {user["id"] for user in users}:
          return chat
    timestamp = now_iso()
    chat_id = f"mock-chat-{uuid.uuid4().hex}"
    chat = {
        "id": chat_id,
        "topic": topic if chat_type == "group" else None,
        "createdDateTime": timestamp,
        "lastUpdatedDateTime": timestamp,
        "chatType": chat_type,
        "webUrl": f"https://teams.microsoft.com/mock/chat/{chat_id}",
        "viewpoint": {"lastMessageReadDateTime": timestamp},
        "lastMessagePreview": None,
    }
    self.state["chats"].append(chat)
    self.state["chatMessages"][chat_id] = []
    self.state["chatMembers"][chat_id] = [
        _member(f"mock-member-{uuid.uuid4().hex}", user) for user in users
    ]
    self._write()
    return chat

  def _sync(self, args: list[str]) -> dict[str, Any]:
    scope = option(args, "--scope", required=False) or "chats"
    initialized: bool
    with TeamsCache() as cache:
      initialized = cache.get_meta("last_sync") is not None
      cache.upsert_resources("chat", self.state["chats"])
      inserted = changed = 0
      for chat in self.state["chats"]:
        result = cache.upsert_messages(
            "chat", chat["id"], self.state["chatMessages"].get(chat["id"], [])
        )
        inserted += result["inserted"]
        changed += result["changed"]
      channel_count = 0
      if scope == "all":
        cache.upsert_resources("team", self.state["teams"])
        for team in self.state["teams"]:
          team_id = team["id"]
          channels = self.state["channels"].get(team_id, [])
          cache.upsert_resources("channel", channels, parent_id=team_id)
          for channel in channels:
            channel_id = channel["id"]
            values = self.state["channelMessages"].get(
                f"{team_id}/{channel_id}", []
            )
            channel_count += len(values)
            result = cache.upsert_messages(
                "channel",
                channel_id,
                values,
                team_id=team_id,
                channel_id=channel_id,
            )
            inserted += result["inserted"]
            changed += result["changed"]
            for root in values:
              replies = self.state["channelReplies"].get(
                  f"{team_id}/{channel_id}/{root['id']}", []
              )
              result = cache.upsert_messages(
                  "channel",
                  channel_id,
                  replies,
                  team_id=team_id,
                  channel_id=channel_id,
                  root_message_id=root["id"],
              )
              inserted += result["inserted"]
              changed += result["changed"]
      cache.set_meta("last_sync", now_iso())
      cache.connection.commit()
      cache_status = cache.status()
    return {
        "initialized": initialized,
        "newMessages": inserted if initialized else 0,
        "changedMessages": changed if initialized else 0,
        "chats": len(self.state["chats"]),
        "teams": len(self.state["teams"]) if scope == "all" else 0,
        "channelMessages": channel_count,
        "errors": [],
        "cache": cache_status,
    }

  def execute(self, args: list[str]) -> Any:
    """Execute ARGS using only local state."""
    mock_delay()
    if args == ["status"]:
      return self.status()
    if args == ["login"]:
      return self.status()
    if args == ["mock", "reset"]:
      return self.reset()
    if args == ["mock", "info"]:
      return self.info()
    if args[:3] == ["teams", "chat", "list"]:
      metadata_limit = int(option(args, "--metadataLimit", required=False) or 150)
      return copy.deepcopy(self.state["chats"][:metadata_limit])
    if args[:3] == ["teams", "search", "messages"]:
      query = str(option(args, "--query")).casefold()
      limit = int(option(args, "--limit", required=False) or 50)
      offset = int(option(args, "--from", required=False) or 0)
      results: list[dict[str, Any]] = []

      def add(message: dict[str, Any], context: dict[str, Any]) -> None:
        searchable = " ".join([
            str(message.get("subject") or ""),
            str(message.get("summary") or ""),
            str(message.get("body", {}).get("content") or ""),
            str(message.get("from", {}).get("user", {}).get("displayName") or ""),
        ]).casefold()
        if query in searchable:
          item = copy.deepcopy(message)
          item["searchContext"] = context
          results.append(item)

      for chat_id, messages in self.state["chatMessages"].items():
        for message in messages:
          add(message, {"scopeKind": "chat", "scopeId": chat_id})
      for key, messages in self.state["channelMessages"].items():
        team_id, channel_id = key.split("/", 1)
        for message in messages:
          add(message, {
              "scopeKind": "channel", "scopeId": channel_id,
              "teamId": team_id, "channelId": channel_id,
              "rootMessageId": message.get("id"),
          })
      for key, messages in self.state["channelReplies"].items():
        team_id, channel_id, root_id = key.split("/", 2)
        for message in messages:
          add(message, {
              "scopeKind": "channel", "scopeId": channel_id,
              "teamId": team_id, "channelId": channel_id,
              "rootMessageId": root_id,
          })
      results.sort(
          key=lambda item: str(item.get("createdDateTime") or ""), reverse=True
      )
      return results[offset:offset + limit]
    if args[:4] == ["teams", "chat", "member", "batch"]:
      return [
          {
              "chatId": chat_id,
              "members": copy.deepcopy(
                  self.state["chatMembers"].get(chat_id, [])
              ),
              "membersLoaded": True,
          }
          for chat_id in options(args, "--chatId")
      ]
    if args[:4] == ["teams", "meeting", "event", "batch"]:
      try:
        meetings = json.loads(str(option(args, "--meetings")))
      except json.JSONDecodeError as exception:
        raise ValueError("--meetings must be valid JSON") from exception
      if not isinstance(meetings, list):
        raise ValueError("--meetings must be a JSON array")
      records = []
      for meeting in meetings:
        if not isinstance(meeting, dict):
          continue
        chat_id = meeting.get("chatId")
        event = self.state.get("meetingEvents", {}).get(chat_id)
        record = {"chatId": chat_id}
        if isinstance(event, dict):
          record["event"] = copy.deepcopy(event)
        else:
          record["eventError"] = "No linked mock calendar event"
        records.append(record)
      return records
    if args[:4] == ["teams", "meeting", "propose", "suggest"]:
      return self._meeting_time_suggestions(args)
    if args[:4] == ["teams", "meeting", "propose", "send"]:
      return self._propose_meeting_time(args)
    if args[:3] == ["teams", "meeting", "availability"]:
      return self._meeting_availability(args)
    if args[:3] == ["teams", "meeting", "respond"]:
      return self._respond_to_meeting(args)
    if args[:3] == ["teams", "meeting", "context"]:
      chat_id = str(option(args, "--chatId"))
      chat = self._chat(chat_id)
      if chat.get("chatType") != "meeting":
        raise ValueError("Meeting context requires a meeting chat")
      event = self.state.get("meetingEvents", {}).get(chat_id)
      return {
          "chatId": chat_id,
          "members": copy.deepcopy(self.state["chatMembers"].get(chat_id, [])),
          "membersLoaded": True,
          "onlineMeetingInfo": copy.deepcopy(chat.get("onlineMeetingInfo") or {}),
          "event": copy.deepcopy(event),
      }
    if args[:3] == ["teams", "meeting", "transcript"]:
      chat_id = str(option(args, "--chatId"))
      transcript = self.state.get("meetingTranscripts", {}).get(chat_id)
      if not isinstance(transcript, dict):
        raise ValueError("No transcript is available for this mock meeting")
      event = copy.deepcopy(self.state.get("meetingEvents", {}).get(chat_id) or {})
      return {
          "chatId": chat_id,
          "meeting": {
              "id": "mock-online-meeting-architecture-review",
              "subject": event.get("subject") or "Mock meeting",
          },
          "event": event,
          "transcript": {
              key: copy.deepcopy(value)
              for key, value in transcript.items()
              if key != "content"
          },
          "contentType": "text/vtt",
          "content": transcript.get("content", ""),
      }
    if args[:4] == ["teams", "chat", "member", "list"]:
      return self.state["chatMembers"].get(str(option(args, "--chatId")), [])
    if args[:4] == ["teams", "chat", "message", "export"]:
      messages = copy.deepcopy(self.state["chatMessages"].get(
          str(option(args, "--chatId")), []
      ))
      created = sorted(
          value
          for message in messages
          if isinstance((value := message.get("createdDateTime")), str) and value
      )
      return {
          "value": messages,
          "history": {
              "complete": True,
              "pageCount": 1 if messages else 0,
              "messageCount": len(messages),
              "oldestDateTime": created[0] if created else None,
              "newestDateTime": created[-1] if created else None,
          },
      }
    if args[:4] == ["teams", "chat", "message", "list"]:
      messages = self.state["chatMessages"].get(
          str(option(args, "--chatId")), []
      )
      requested_limit = option(args, "--limit", required=False)
      if requested_limit is not None:
        return messages[-int(requested_limit):]
      return messages
    if args[:3] == ["teams", "chat", "get"]:
      wanted = {
          item.strip().casefold()
          for item in str(option(args, "--participants")).split(",")
      }
      for chat in self.state["chats"]:
        member_emails = {
            str(member.get("email", "")).casefold()
            for member in self.state["chatMembers"].get(chat["id"], [])
            if member.get("userId") != self.state["profile"]["id"]
        }
        if wanted == member_emails:
          return chat
      raise ValueError("No existing mock chat for those participants")
    if args[:4] == ["teams", "chat", "message", "send"]:
      return self._send_chat(args)
    if args[:4] == ["teams", "chat", "mark", "read"]:
      chat = self._chat(str(option(args, "--chatId")))
      chat["viewpoint"]["lastMessageReadDateTime"] = chat["lastUpdatedDateTime"]
      self._write()
      return chat
    if args[:4] == ["teams", "chat", "mark", "unread"]:
      chat = self._chat(str(option(args, "--chatId")))
      chat["viewpoint"]["lastMessageReadDateTime"] = "1970-01-01T00:00:00Z"
      self._write()
      return chat
    if args[:3] == ["teams", "chat", "create"]:
      return self._create_chat(args)
    if args[:4] == ["teams", "chat", "topic", "set"]:
      chat = self._chat(str(option(args, "--chatId")))
      if chat.get("chatType") != "group":
        raise ValueError("Only group chats can have a topic")
      chat["topic"] = str(option(args, "--topic"))
      chat["lastUpdatedDateTime"] = now_iso()
      self._write()
      return chat
    if args[:4] == ["teams", "chat", "member", "add"]:
      chat_id = str(option(args, "--chatId"))
      user = self._user(str(option(args, "--userId")))
      member = _member(f"mock-member-{uuid.uuid4().hex}", user)
      members = self.state["chatMembers"].setdefault(chat_id, [])
      if user["id"] not in {item.get("userId") for item in members}:
        members.append(member)
        self._write()
      return member
    if args[:4] == ["teams", "chat", "member", "remove"]:
      chat_id = str(option(args, "--chatId"))
      membership_id = str(option(args, "--membershipId"))
      members = self.state["chatMembers"].setdefault(chat_id, [])
      before = len(members)
      members[:] = [item for item in members if item.get("id") != membership_id]
      if len(members) == before:
        raise ValueError(f"Unknown mock membership: {membership_id}")
      self._write()
      return {}
    if args == ["teams", "team", "list"]:
      return self.state["teams"]
    if args[:3] == ["teams", "channel", "list"]:
      return self.state["channels"].get(str(option(args, "--teamId")), [])
    if args[:4] == ["teams", "channel", "message", "list"]:
      key = f"{option(args, '--teamId')}/{option(args, '--channelId')}"
      return self.state["channelMessages"].get(key, [])
    if args[:4] == ["teams", "channel", "reply", "list"]:
      key = (
          f"{option(args, '--teamId')}/{option(args, '--channelId')}/"
          f"{option(args, '--messageId')}"
      )
      return self.state["channelReplies"].get(key, [])
    if args[:4] == ["teams", "channel", "message", "send"]:
      return self._send_channel(args)
    if args[:3] == ["teams", "message", "react"]:
      return self._react(args, True)
    if args[:3] == ["teams", "message", "unreact"]:
      return self._react(args, False)
    if args[:3] == ["teams", "message", "edit"]:
      return self._edit(args)
    if args[:3] == ["teams", "message", "delete"]:
      return self._delete(args)
    if args[:3] == ["teams", "message", "restore"]:
      return self._restore(args)
    if args[:3] == ["teams", "user", "search"]:
      query = str(option(args, "--query")).casefold()
      return [
          user
          for user in self.state["users"]
          if query
          in " ".join(
              str(user.get(key, ""))
              for key in ("displayName", "mail", "userPrincipalName", "jobTitle")
          ).casefold()
      ]
    if args[:3] == ["teams", "user", "profile"]:
      return self._user(str(option(args, "--userId")))
    if args[:3] == ["teams", "user", "presence"]:
      return self._user(str(option(args, "--userId")))["presence"]
    if args[:3] == ["teams", "attachment", "download"]:
      source_url = str(option(args, "--url"))
      destination = Path(str(option(args, "--destination"))).expanduser()
      if not source_url.startswith("file://"):
        raise ValueError("Mock attachments must use a local file URL")
      from urllib.parse import unquote, urlparse

      source = Path(unquote(urlparse(source_url).path))
      destination.parent.mkdir(parents=True, exist_ok=True)
      shutil.copy2(source, destination)
      try:
        destination.chmod(0o600)
      except OSError:
        pass
      return {"path": str(destination), "bytes": destination.stat().st_size}
    if args[:2] == ["teams", "sync"]:
      return self._sync(args)
    if args[:3] == ["teams", "cache", "search"]:
      with TeamsCache() as cache:
        return cache.search(
            str(option(args, "--query")),
            limit=int(option(args, "--limit", required=False) or "100"),
            scope_kind=option(args, "--scope", required=False),
            scope_id=option(args, "--scopeId", required=False),
        )
    if args == ["teams", "cache", "status"]:
      with TeamsCache() as cache:
        return cache.status()
    if args == ["teams", "cache", "clear"]:
      with TeamsCache() as cache:
        cache.clear()
        return cache.status()
    raise ValueError(f"Unsupported mock backend command: {args!r}")
