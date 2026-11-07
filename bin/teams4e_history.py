# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded newest-first history selection shared by Graph and the mock tenant."""

from datetime import datetime, timezone


def message_time(value):
  """Return an aware UTC timestamp, or None for an undated/malformed message."""
  try:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed.astimezone(timezone.utc) if parsed.tzinfo else None
  except (AttributeError, TypeError, ValueError):
    return None


def bounded_history(pages, *, since=None, limit=None, progress=None):
  """Consume newest-created-first PAGES only until the date or row bound.

  PAGES is lazy: stopping this iterator must stop further network pagination.
  Undated messages are retained and counted, never used as a date boundary.
  A bounded snapshot never claims to be the complete lifetime of the chat.
  """
  cutoff = message_time(since) if since is not None else None
  if since is not None and cutoff is None:
    raise ValueError("Snapshot --since must be an ISO date-time with a timezone")
  if limit is not None and (type(limit) is not int or limit <= 0):
    raise ValueError("Snapshot --limit must be a positive integer")
  if cutoff is None and limit is None:
    raise ValueError("Snapshot requires --since or --limit; use export for full history")
  messages, dates = [], []
  page_count, undated = 0, 0
  reason, stopped = "exhausted", False
  for page in pages:
    page_count += 1
    values = page.get("value")
    if not isinstance(values, list):
      raise ValueError("Microsoft Graph collection has no value array")
    for offset, message in enumerate(values):
      if not isinstance(message, dict):
        raise ValueError("Microsoft Graph returned a malformed message")
      created = message_time(message.get("createdDateTime"))
      if cutoff is not None and created is not None and created < cutoff:
        reason, stopped = "date", True
        break
      messages.append(message)
      if created is not None:
        dates.append(created)
      else:
        undated += 1
      if limit is not None and len(messages) >= limit:
        reason = ("messageLimit" if offset + 1 < len(values)
                  or page.get("@odata.nextLink") else "exhausted")
        stopped = True
        break
    if progress:
      progress(page_count, len(messages))
    if stopped:
      break
  return {
      "value": messages,
      "history": {
          "complete": False,
          "bounded": True,
          "since": since,
          "limit": limit,
          "stopReason": reason,
          "pageCount": page_count,
          "messageCount": len(messages),
          "undatedMessageCount": undated,
          "oldestDateTime": min(dates).isoformat().replace("+00:00", "Z") if dates else None,
          "newestDateTime": max(dates).isoformat().replace("+00:00", "Z") if dates else None,
      },
  }
