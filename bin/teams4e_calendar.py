# SPDX-License-Identifier: GPL-3.0-or-later
"""Pure validation shared by real and synthetic calendar creation."""
from datetime import datetime, timezone
import re
from uuid import UUID


def calendar_draft_payload(draft):
    """Validate a timed, non-recurring draft and produce a Graph event payload."""
    if not isinstance(draft, dict):
        raise ValueError("Calendar draft must be a JSON object")
    allowed = {"subject", "start", "end", "required", "optional", "body",
               "location", "online", "showAs", "transactionId"}
    if set(draft) - allowed:
        raise ValueError("Unsupported calendar draft fields")
    subject = draft.get("subject")
    if not isinstance(subject, str) or not subject.strip():
        raise ValueError("A meeting title is required")
    if len(subject) > 255 or any(c in subject for c in "\r\n"):
        raise ValueError("Meeting title must be one line, at most 255 characters")
    times = []
    for field in ("start", "end"):
        raw = draft.get(field)
        if not isinstance(raw, str):
            raise ValueError(f"{field} must include a date, time, and UTC offset")
        value = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        if value.tzinfo is None:
            raise ValueError(f"{field} must include a UTC offset")
        times.append(value.astimezone(timezone.utc))
    if times[1] <= times[0]:
        raise ValueError("Meeting end must be after its start")
    if (times[1] - times[0]).total_seconds() > 7 * 86400:
        raise ValueError("Use Outlook for meetings longer than seven days")
    transaction = draft.get("transactionId")
    if not isinstance(transaction, str):
        raise ValueError("A stable transactionId is required for safe retries")
    UUID(transaction)
    attendees, seen = [], set()
    for field, kind in (("required", "required"), ("optional", "optional")):
        values = draft.get(field, [])
        if not isinstance(values, list):
            raise ValueError(f"{field} attendees must be an array of email addresses")
        for address in values:
            if not isinstance(address, str) or not re.fullmatch(r"[^\s<>,;@]+@[^\s<>,;@]+", address):
                raise ValueError("Attendees must be plain email addresses")
            if address.casefold() not in seen:
                attendees.append({"emailAddress": {"address": address}, "type": kind})
                seen.add(address.casefold())
    if len(attendees) > 500:
        raise ValueError("At most 500 attendees are supported")
    online = draft.get("online", False)
    if not isinstance(online, bool):
        raise ValueError("online must be a boolean")
    show_as = draft.get("showAs", "busy")
    if show_as not in ("free", "tentative", "busy", "oof", "workingElsewhere"):
        raise ValueError("Invalid showAs value")
    for field in ("body", "location"):
        if not isinstance(draft.get(field, ""), str):
            raise ValueError(f"{field} must be text")
    result = {
        "subject": subject.strip(),
        "start": {"dateTime": times[0].strftime("%Y-%m-%dT%H:%M:%S"), "timeZone": "UTC"},
        "end": {"dateTime": times[1].strftime("%Y-%m-%dT%H:%M:%S"), "timeZone": "UTC"},
        "attendees": attendees,
        "body": {"contentType": "HTML", "content": draft.get("body", "")},
        "location": {"displayName": draft.get("location", "")},
        "showAs": show_as,
        "isOnlineMeeting": online,
        "responseRequested": True,
        "transactionId": transaction,
    }
    if online:
        result["onlineMeetingProvider"] = "teamsForBusiness"
    return result
