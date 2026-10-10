# SPDX-License-Identifier: GPL-3.0-or-later
"""Durable local scheduling; no credentials, network calls, or background daemon."""
from __future__ import annotations

import json
import math
import os
import re
import sqlite3
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo


class RetryLater(Exception):
    """A known rejected HTTP 429, safe to retry after the indicated delay."""

    def __init__(self, delay):
        self.delay = max(1, delay)


class Rejected(Exception):
    """A known rejected request; human review is required."""


def local_zone(name=None):
    if name or os.environ.get("TZ"):
        return ZoneInfo(name or os.environ["TZ"].lstrip(":"))
    with open("/etc/localtime", "rb") as source:
        return ZoneInfo.from_file(source, key="system-local")


def wall_times(wall, zone):
    """Return distinct real instants for a wall time (zero, one, or two)."""
    instants = set()
    for fold in (0, 1):
        candidate = wall.replace(tzinfo=zone, fold=fold)
        if candidate.astimezone(timezone.utc).astimezone(zone).replace(tzinfo=None) == wall:
            instants.add(candidate.timestamp())
    return sorted(instants)


def schedule_time(spec, now=None):
    """Resolve civil time before storing an absolute instant, never adding 24h."""
    now = time.time() if now is None else now
    zone = local_zone(spec.get("zone"))
    if spec.get("mode") == "next":
        days = spec.get("days")
        start = spec.get("start", "07:00")
        if (not isinstance(days, list) or not days or
                any(type(day) is not int or day not in range(7) for day in days)):
            raise ValueError("Configure at least one workday (0=Sunday through 6=Saturday)")
        if not isinstance(start, str) or not re.fullmatch(r"(?:[01]\d|2[0-3]):[0-5]\d", start):
            raise ValueError("Workday start must be HH:MM")
        date = datetime.fromtimestamp(now, zone).date()
        for offset in range(1, 8):
            day = date + timedelta(days=offset)
            if (day.weekday() + 1) % 7 in days:
                break
        hour, minute = map(int, start.split(":"))
        wall = datetime(day.year, day.month, day.day, hour, minute)
        # A DST gap moves forward to the first real local minute. Repeated
        # hours use the earlier occurrence. Explicit times must disambiguate.
        for _ in range(181):
            choices = wall_times(wall, zone)
            if choices:
                instant = choices[0]
                break
            wall += timedelta(minutes=1)
        else:
            raise ValueError("No real workday start near the configured time")
    elif spec.get("mode") == "explicit":
        if not re.match(r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}", spec.get("value", "")):
            raise ValueError("Specify both a date and time: YYYY-MM-DD HH:MM")
        wall = datetime.fromisoformat(spec["value"].replace("Z", "+00:00"))
        if wall.tzinfo is not None:
            instant = wall.timestamp()
        else:
            choices = wall_times(wall, zone)
            if len(choices) != 1:
                raise ValueError("DST gap or repeated time: specify an explicit UTC offset")
            instant = choices[0]
    else:
        raise ValueError("Choose next workday or an explicit date/time")
    if instant <= now:
        raise ValueError("Scheduled time must be in the future")
    return {"sendAt": instant,
            "displayTime": datetime.fromtimestamp(instant, zone).strftime("%Y-%m-%d %H:%M:%S %Z %z"),
            "zone": str(zone)}


class Outbox:
    """One canonical SQLite queue; durable claims prevent concurrent delivery."""

    def __init__(self, path):
        path = Path(path).expanduser()
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if path.is_symlink():
            raise ValueError("Outbox must not be a symbolic link")
        fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        os.close(fd)
        path.chmod(0o600)
        self.db = sqlite3.connect(path, timeout=10)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.execute("""CREATE TABLE IF NOT EXISTS jobs (
            id TEXT PRIMARY KEY, owner TEXT NOT NULL, state TEXT NOT NULL,
            revision INTEGER NOT NULL, due REAL NOT NULL, next_attempt REAL NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0, updated REAL NOT NULL,
            record TEXT NOT NULL, note TEXT NOT NULL DEFAULT '', message_id TEXT)""")
        self.db.commit()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.db.close()

    @staticmethod
    def unpack(row):
        if row is None:
            raise ValueError("Scheduled message no longer exists")
        record = json.loads(row["record"])
        record.update({key: row[key] for key in
                       ("id", "owner", "state", "revision", "attempts", "note", "message_id")})
        return record

    def get(self, identifier):
        return self.unpack(self.db.execute("SELECT * FROM jobs WHERE id=?", (identifier,)).fetchone())

    def list(self):
        return [self.unpack(row) for row in self.db.execute("SELECT * FROM jobs ORDER BY due,id")]

    def put(self, identifier, owner, record, revision=None, now=None):
        now = time.time() if now is None else now
        if not re.fullmatch(r"[a-zA-Z0-9-]{16,80}", identifier) or not owner:
            raise ValueError("Invalid outbox identity")
        if not math.isfinite(record["sendAt"]):
            raise ValueError("Scheduled time must be finite")
        encoded = json.dumps(record, ensure_ascii=False, sort_keys=True)
        with self.db:
            self.db.execute("BEGIN IMMEDIATE")
            old = self.db.execute("SELECT * FROM jobs WHERE id=?", (identifier,)).fetchone()
            # Retrying a lost enqueue response must not create a second job.
            if old and old["record"] == encoded and old["owner"] == owner and revision is None:
                return self.unpack(old)
            if record["sendAt"] <= now:
                raise ValueError("Scheduled time has passed; choose another time")
            if old:
                if old["owner"] != owner or old["revision"] != revision or old["state"] != "held":
                    raise ValueError("Outbox changed: reload and hold the message before editing")
                self.db.execute("""UPDATE jobs SET state='scheduled',revision=revision+1,
                    due=?,next_attempt=?,attempts=0,updated=?,record=?,note='' WHERE id=?""",
                    (record["sendAt"], record["sendAt"], now, encoded, identifier))
            else:
                if revision is not None:
                    raise ValueError("Cannot replace a missing scheduled message")
                self.db.execute("""INSERT INTO jobs
                    (id,owner,state,revision,due,next_attempt,updated,record)
                    VALUES (?,?,'scheduled',0,?,?,?,?)""",
                    (identifier, owner, record["sendAt"], record["sendAt"], now, encoded))
        return self.get(identifier)

    def change(self, identifier, state):
        if state not in ("held", "cancelled"):
            raise ValueError("Invalid outbox action")
        with self.db:
            result = self.db.execute("""UPDATE jobs SET state=?,revision=revision+1,updated=?
                WHERE id=? AND state IN ('scheduled','retry','held')""",
                (state, time.time(), identifier))
            if not result.rowcount:
                raise ValueError("Message is sending, sent, uncertain or cancelled; it cannot be edited/cancelled")
        return self.get(identifier)

    def run_one(self, authenticate, send, grace=900, now=None):
        realtime = now is None
        now = time.time() if now is None else now
        if grace < 0:
            raise ValueError("Late-send grace must be nonnegative")
        with self.db:
            self.db.execute("""UPDATE jobs SET state='uncertain',note='Interrupted send; verify in Teams before composing again'
                WHERE state='sending' AND updated<?""", (now - 300,))
            self.db.execute("""UPDATE jobs SET state='held',revision=revision+1,note='Missed delivery window; reschedule explicitly'
                WHERE state IN ('scheduled','retry') AND due<?""", (now - grace,))
        row = self.db.execute("""SELECT * FROM jobs WHERE state IN ('scheduled','retry')
            AND next_attempt<=? ORDER BY due,id LIMIT 1""", (now,)).fetchone()
        if row is None:
            return {"state": "idle"}
        # Acquire credentials before claiming: failure here cannot have sent.
        owner, credential = authenticate()
        if realtime:
            now = time.time()
        if now - row["due"] > grace:
            with self.db:
                self.db.execute("""UPDATE jobs SET state='held',revision=revision+1,
                    note='Missed delivery window during authentication; reschedule'
                    WHERE id=? AND revision=? AND state IN ('scheduled','retry')""",
                    (row["id"], row["revision"]))
            return self.get(row["id"])
        with self.db:
            if owner != row["owner"]:
                self.db.execute("""UPDATE jobs SET state='held',revision=revision+1,
                    note='Sending account changed; review before rescheduling'
                    WHERE id=? AND revision=? AND state IN ('scheduled','retry')""",
                    (row["id"], row["revision"]))
                return self.get(row["id"])
            claimed = self.db.execute("""UPDATE jobs SET state='sending',attempts=attempts+1,updated=?
                WHERE id=? AND revision=? AND state IN ('scheduled','retry')""",
                (now, row["id"], row["revision"]))
        if not claimed.rowcount:
            return {"state": "idle"}
        record = json.loads(row["record"])
        state, note, message_id, next_attempt = "sent", "", None, now
        try:
            result = send(record, credential)
            if not isinstance(result, dict) or not result.get("id"):
                raise ValueError("Missing send acknowledgement")
            message_id = result["id"]
        except RetryLater as error:
            next_attempt = now + error.delay
            state = "retry" if row["attempts"] < 4 else "held"
            note = "Throttled; retry scheduled" if state == "retry" else "Repeated throttling; reschedule explicitly"
        except Rejected:
            state, note = "held", "Graph rejected the send; check authentication/permissions and reschedule"
        except Exception:
            # A lost response may mean successful delivery. Graph's send API
            # has no documented idempotency key. Never automatically replay it.
            state, note = "uncertain", "Delivery unknown; verify in Teams before composing again"
        with self.db:
            self.db.execute("""UPDATE jobs SET state=?,note=?,message_id=?,next_attempt=?,
                updated=?,revision=revision+1 WHERE id=?""",
                (state, note, message_id, next_attempt, now, row["id"]))
        return self.get(row["id"])
