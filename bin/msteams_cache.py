# SPDX-License-Identifier: GPL-3.0-or-later
"""Private SQLite cache for the msteams Teams backend."""

from __future__ import annotations

import json
import os
import sqlite3
import time
from pathlib import Path
from typing import Any, Iterable


SCHEMA_VERSION = "1"


def default_cache_path() -> Path:
  """Return the configured cache path without creating it."""
  configured = os.environ.get("MSTEAMS_CACHE")
  if configured:
    return Path(configured).expanduser()
  root = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
  return root / "msteams" / "teams.sqlite3"


def _message_text(message: dict[str, Any]) -> str:
  body = message.get("body")
  if not isinstance(body, dict):
    return ""
  content = body.get("content")
  return content if isinstance(content, str) else ""


def _sender(message: dict[str, Any]) -> str:
  sender = message.get("from")
  if not isinstance(sender, dict):
    return ""
  for identity_type in ("user", "application", "device"):
    identity = sender.get(identity_type)
    if isinstance(identity, dict):
      name = identity.get("displayName")
      if isinstance(name, str):
        return name
  return ""


class TeamsCache:
  """Small cache used for incremental polling, saved search, and offline reads."""

  def __init__(self, path: Path | None = None) -> None:
    self.path = (path or default_cache_path()).expanduser()
    self.path.parent.mkdir(parents=True, exist_ok=True)
    try:
      self.path.parent.chmod(0o700)
    except OSError:
      pass
    self.connection = sqlite3.connect(self.path)
    self.connection.row_factory = sqlite3.Row
    self.connection.execute("PRAGMA busy_timeout=5000")
    self.connection.execute("PRAGMA journal_mode=WAL")
    self.connection.execute("PRAGMA foreign_keys=ON")
    self._create_schema()
    try:
      self.path.chmod(0o600)
    except OSError:
      pass

  def close(self) -> None:
    self.connection.close()

  def __enter__(self) -> "TeamsCache":
    return self

  def __exit__(self, *_args: object) -> None:
    self.close()

  def _create_schema(self) -> None:
    self.connection.executescript(
        """
        CREATE TABLE IF NOT EXISTS metadata (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS resources (
          kind TEXT NOT NULL,
          resource_id TEXT NOT NULL,
          parent_id TEXT NOT NULL DEFAULT '',
          secondary_parent_id TEXT NOT NULL DEFAULT '',
          updated_at TEXT NOT NULL DEFAULT '',
          payload TEXT NOT NULL,
          cached_at REAL NOT NULL,
          PRIMARY KEY (kind, resource_id, parent_id, secondary_parent_id)
        );
        CREATE INDEX IF NOT EXISTS resources_parent
          ON resources(kind, parent_id, secondary_parent_id, updated_at);
        CREATE TABLE IF NOT EXISTS messages (
          scope_kind TEXT NOT NULL,
          scope_id TEXT NOT NULL,
          team_id TEXT NOT NULL DEFAULT '',
          channel_id TEXT NOT NULL DEFAULT '',
          root_message_id TEXT NOT NULL DEFAULT '',
          message_id TEXT NOT NULL,
          created_at TEXT NOT NULL DEFAULT '',
          modified_at TEXT NOT NULL DEFAULT '',
          sender TEXT NOT NULL DEFAULT '',
          body TEXT NOT NULL DEFAULT '',
          payload TEXT NOT NULL,
          cached_at REAL NOT NULL,
          PRIMARY KEY (
            scope_kind, scope_id, team_id, channel_id,
            root_message_id, message_id
          )
        );
        CREATE INDEX IF NOT EXISTS messages_scope
          ON messages(scope_kind, scope_id, created_at);
        CREATE INDEX IF NOT EXISTS messages_modified
          ON messages(modified_at);
        """
    )
    self.set_meta("schema_version", SCHEMA_VERSION)
    self.connection.commit()

  def get_meta(self, key: str) -> str | None:
    row = self.connection.execute(
        "SELECT value FROM metadata WHERE key = ?", (key,)
    ).fetchone()
    return str(row["value"]) if row else None

  def set_meta(self, key: str, value: str) -> None:
    self.connection.execute(
        """
        INSERT INTO metadata(key, value) VALUES(?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """,
        (key, value),
    )

  def upsert_resources(
      self,
      kind: str,
      values: Iterable[dict[str, Any]],
      *,
      parent_id: str = "",
      secondary_parent_id: str = "",
  ) -> int:
    count = 0
    now = time.time()
    for value in values:
      resource_id = value.get("id")
      if not isinstance(resource_id, str) or not resource_id:
        continue
      updated = next(
          (
              value.get(key)
              for key in (
                  "lastUpdatedDateTime",
                  "lastModifiedDateTime",
                  "createdDateTime",
              )
              if isinstance(value.get(key), str)
          ),
          "",
      )
      self.connection.execute(
          """
          INSERT INTO resources(
            kind, resource_id, parent_id, secondary_parent_id,
            updated_at, payload, cached_at
          ) VALUES(?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(kind, resource_id, parent_id, secondary_parent_id)
          DO UPDATE SET
            updated_at = excluded.updated_at,
            payload = excluded.payload,
            cached_at = excluded.cached_at
          """,
          (
              kind,
              resource_id,
              parent_id,
              secondary_parent_id,
              updated,
              json.dumps(value, ensure_ascii=False, separators=(",", ":")),
              now,
          ),
      )
      count += 1
    self.connection.commit()
    return count

  def list_resources(
      self,
      kind: str,
      *,
      parent_id: str | None = None,
      secondary_parent_id: str | None = None,
  ) -> list[dict[str, Any]]:
    clauses = ["kind = ?"]
    parameters: list[str] = [kind]
    if parent_id is not None:
      clauses.append("parent_id = ?")
      parameters.append(parent_id)
    if secondary_parent_id is not None:
      clauses.append("secondary_parent_id = ?")
      parameters.append(secondary_parent_id)
    rows = self.connection.execute(
        f"SELECT payload FROM resources WHERE {' AND '.join(clauses)} "
        "ORDER BY updated_at DESC",
        parameters,
    ).fetchall()
    return [json.loads(str(row["payload"])) for row in rows]

  def upsert_messages(
      self,
      scope_kind: str,
      scope_id: str,
      values: Iterable[dict[str, Any]],
      *,
      team_id: str = "",
      channel_id: str = "",
      root_message_id: str = "",
  ) -> dict[str, int]:
    inserted = 0
    changed = 0
    unchanged = 0
    now = time.time()
    for value in values:
      message_id = value.get("id")
      if not isinstance(message_id, str) or not message_id:
        continue
      payload = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
      previous = self.connection.execute(
          """
          SELECT payload FROM messages
          WHERE scope_kind = ? AND scope_id = ? AND team_id = ?
            AND channel_id = ? AND root_message_id = ? AND message_id = ?
          """,
          (
              scope_kind,
              scope_id,
              team_id,
              channel_id,
              root_message_id,
              message_id,
          ),
      ).fetchone()
      if previous is None:
        inserted += 1
      elif str(previous["payload"]) != payload:
        changed += 1
      else:
        unchanged += 1
      self.connection.execute(
          """
          INSERT INTO messages(
            scope_kind, scope_id, team_id, channel_id, root_message_id,
            message_id, created_at, modified_at, sender, body, payload, cached_at
          ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(
            scope_kind, scope_id, team_id, channel_id,
            root_message_id, message_id
          ) DO UPDATE SET
            created_at = excluded.created_at,
            modified_at = excluded.modified_at,
            sender = excluded.sender,
            body = excluded.body,
            payload = excluded.payload,
            cached_at = excluded.cached_at
          """,
          (
              scope_kind,
              scope_id,
              team_id,
              channel_id,
              root_message_id,
              message_id,
              value.get("createdDateTime") or "",
              value.get("lastModifiedDateTime") or "",
              _sender(value),
              _message_text(value),
              payload,
              now,
          ),
      )
    self.connection.commit()
    return {"inserted": inserted, "changed": changed, "unchanged": unchanged}

  def list_messages(
      self,
      scope_kind: str,
      scope_id: str,
      *,
      team_id: str = "",
      channel_id: str = "",
      root_message_id: str | None = None,
      limit: int | None = None,
  ) -> list[dict[str, Any]]:
    clauses = [
        "scope_kind = ?",
        "scope_id = ?",
        "team_id = ?",
        "channel_id = ?",
    ]
    parameters: list[Any] = [scope_kind, scope_id, team_id, channel_id]
    if root_message_id is not None:
      clauses.append("root_message_id = ?")
      parameters.append(root_message_id)
    query = (
        "SELECT payload FROM messages WHERE "
        + " AND ".join(clauses)
        + " ORDER BY created_at DESC"
    )
    if limit is not None:
      query += " LIMIT ?"
      parameters.append(limit)
    rows = self.connection.execute(query, parameters).fetchall()
    return [json.loads(str(row["payload"])) for row in rows]

  def search(
      self,
      query: str,
      *,
      limit: int = 100,
      scope_kind: str | None = None,
      scope_id: str | None = None,
  ) -> list[dict[str, Any]]:
    terms = [term.casefold() for term in query.split() if term.strip()]
    clauses: list[str] = []
    parameters: list[Any] = []
    for term in terms:
      clauses.append("(lower(sender) LIKE ? OR lower(body) LIKE ?)")
      pattern = f"%{term}%"
      parameters.extend((pattern, pattern))
    if scope_kind:
      clauses.append("scope_kind = ?")
      parameters.append(scope_kind)
    if scope_id:
      clauses.append("scope_id = ?")
      parameters.append(scope_id)
    where = " AND ".join(clauses) if clauses else "1 = 1"
    parameters.append(max(1, min(limit, 1000)))
    rows = self.connection.execute(
        """
        SELECT scope_kind, scope_id, team_id, channel_id, root_message_id,
               message_id, sender, body, created_at, payload
        FROM messages
        WHERE """
        + where
        + " ORDER BY created_at DESC LIMIT ?",
        parameters,
    ).fetchall()
    results: list[dict[str, Any]] = []
    for row in rows:
      payload = json.loads(str(row["payload"]))
      payload["cacheContext"] = {
          "scopeKind": row["scope_kind"],
          "scopeId": row["scope_id"],
          "teamId": row["team_id"],
          "channelId": row["channel_id"],
          "rootMessageId": row["root_message_id"],
      }
      results.append(payload)
    return results

  def status(self) -> dict[str, Any]:
    counts = {
        str(row["kind"]): int(row["count"])
        for row in self.connection.execute(
            "SELECT kind, count(*) AS count FROM resources GROUP BY kind"
        )
    }
    message_counts = {
        str(row["scope_kind"]): int(row["count"])
        for row in self.connection.execute(
            "SELECT scope_kind, count(*) AS count "
            "FROM messages GROUP BY scope_kind"
        )
    }
    return {
        "path": str(self.path),
        "schemaVersion": self.get_meta("schema_version"),
        "lastSync": self.get_meta("last_sync"),
        "resources": counts,
        "messages": message_counts,
    }

  def clear(self) -> None:
    self.connection.executescript(
        "DELETE FROM messages; DELETE FROM resources; DELETE FROM metadata;"
    )
    self.set_meta("schema_version", SCHEMA_VERSION)
    self.connection.commit()
