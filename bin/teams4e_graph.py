# SPDX-License-Identifier: GPL-3.0-or-later
"""Microsoft Graph backend for the teams4e Emacs package."""

from __future__ import annotations

import base64
import html
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from teams4e_cache import TeamsCache
from teams4e_mock import MockTenant, mock_enabled


GRAPH_ROOT = "https://graph.microsoft.com/v1.0"
GRAPH_HOST = "graph.microsoft.com"
SERVER_NAME = "m365"
SERVER_URL: str | None = None
TOKEN_REFRESH_MARGIN_MILLIS = 5 * 60 * 1000
TOKEN_COMMAND_REFRESH_MARGIN_SECONDS = 60
GRAPH_RETRY_ATTEMPTS = 4
GRAPH_MAX_RETRY_SECONDS = 60
TOKEN_REFRESH_LOCK = threading.Lock()
TOKEN_COMMAND_CACHE: tuple[str, int] | None = None
MEETING_EVENT_SELECT = (
    "id,subject,start,end,isAllDay,isCancelled,showAs,responseStatus,"
    "location,locations,organizer,attendees,onlineMeeting,onlineMeetingUrl,webLink,"
    "allowNewTimeProposals,isOrganizer,responseRequested,type"
)
GET_SCHEDULE_BATCH_LIMIT = 20


class BackendError(RuntimeError):
  """A user-facing backend failure."""


def credentials_path() -> Path:
  """Return the configured read-only Graph credential store path."""
  configured = os.environ.get("TEAMS4E_CREDENTIALS")
  if configured:
    return Path(configured).expanduser()
  config_home = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
  return config_home / "teams4e" / "credentials.json"


def credential_server_name() -> str:
  """Return the credential-entry server-name selector."""
  return os.environ.get("TEAMS4E_CREDENTIAL_SERVER_NAME", SERVER_NAME)


def credential_server_url() -> str | None:
  """Return the optional exact credential-entry server URL selector."""
  return os.environ.get("TEAMS4E_CREDENTIAL_SERVER_URL") or SERVER_URL


def resolve_token_command() -> list[str] | None:
  """Return the configured shell-free external token command."""
  raw = os.environ.get("TEAMS4E_TOKEN_COMMAND")
  if not raw:
    return None
  try:
    command = json.loads(raw)
  except json.JSONDecodeError as exception:
    raise BackendError(
        "TEAMS4E_TOKEN_COMMAND must be a JSON argv array"
    ) from exception
  if not (
      isinstance(command, list)
      and command
      and all(isinstance(argument, str) and argument for argument in command)
  ):
    raise BackendError(
        "TEAMS4E_TOKEN_COMMAND must be a nonempty JSON argv array"
    )
  return command


def load_credential_store(path: Path) -> dict[str, Any] | None:
  """Load a credential store, returning nil-like None for unusable files."""
  if not path.exists():
    return None
  try:
    store = json.loads(path.read_text(encoding="utf-8"))
  except (OSError, json.JSONDecodeError):
    return None
  return store if isinstance(store, dict) else None


def find_graph_credential(path: Path) -> dict[str, Any] | None:
  """Find a Graph credential using the configured name and optional URL."""
  store = load_credential_store(path)
  if store is None:
    return None
  server_name = credential_server_name()
  server_url = credential_server_url()
  if server_url:
    for entry in store.values():
      if (
          isinstance(entry, dict)
          and entry.get("server_name") == server_name
          and entry.get("server_url") == server_url
      ):
        return entry
  for entry in store.values():
    if isinstance(entry, dict) and entry.get("server_name") == server_name:
      return entry
  return None


def decode_jwt_payload(token: str | None) -> dict[str, Any]:
  """Decode JWT claims for display only; this does not validate the token."""
  if not isinstance(token, str):
    return {}
  parts = token.split(".")
  if len(parts) < 2:
    return {}
  try:
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    claims = json.loads(base64.urlsafe_b64decode(payload).decode("utf-8"))
  except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
    return {}
  return claims if isinstance(claims, dict) else {}


def graph_token_expiry_millis(entry: dict[str, Any]) -> int | None:
  """Return the Graph access-token expiration in milliseconds."""
  expires_at = entry.get("graph_expires_at")
  if isinstance(expires_at, (int, float)):
    return int(expires_at)
  claims = decode_jwt_payload(entry.get("graph_access_token"))
  expires_at = claims.get("exp")
  if isinstance(expires_at, (int, float)):
    return int(expires_at * 1000)
  return None


def graph_token_is_fresh(entry: dict[str, Any]) -> bool:
  """Return whether ENTRY has a Graph token outside the refresh margin."""
  token = entry.get("graph_access_token")
  expires_at = graph_token_expiry_millis(entry)
  return bool(
      isinstance(token, str)
      and token
      and isinstance(expires_at, int)
      and expires_at > time.time() * 1000 + TOKEN_REFRESH_MARGIN_MILLIS
  )


def resolve_bootstrap_command() -> str | None:
  """Resolve the optional external credential refresh helper."""
  configured = os.environ.get("TEAMS4E_BOOTSTRAP_COMMAND")
  if not configured:
    return None
  expanded = str(Path(configured).expanduser()) if "/" in configured else configured
  if "/" in expanded and Path(expanded).is_file():
    return expanded
  discovered = shutil.which(expanded)
  if discovered:
    return discovered
  return expanded


def run_bootstrap(path: Path, *, interactive: bool = False) -> None:
  """Ask the configured credential owner to create or refresh PATH."""
  program = resolve_bootstrap_command()
  if not program:
    raise BackendError(
        "No Graph token provider is configured; set teams4e-token-command or "
        "teams4e-bootstrap-program"
    )
  command = [
      program,
      "--refresh-if-needed",
      "--credentials",
      str(path),
  ]
  try:
    if interactive:
      process = subprocess.run(command, check=False)
    else:
      process = subprocess.run(
          command,
          stdout=subprocess.PIPE,
          stderr=subprocess.STDOUT,
          text=True,
          check=False,
      )
      output = process.stdout or ""
      if output:
        sys.stderr.write(output)
        if not output.endswith("\n"):
          sys.stderr.write("\n")
  except OSError as exception:
    raise BackendError(
        f"Cannot run Graph credential helper {command[0]}: {exception}"
    ) from exception
  if process.returncode != 0:
    raise BackendError(
        f"Graph credential helper failed with exit {process.returncode}"
    )


def token_command_payload(command: list[str]) -> tuple[str, int]:
  """Run COMMAND without a shell and return token plus Unix expiry seconds."""
  try:
    process = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
  except OSError as exception:
    raise BackendError(
        f"Cannot run Graph token command {command[0]}: {exception}"
    ) from exception
  if process.returncode != 0:
    raise BackendError(
        f"Graph token command failed with exit {process.returncode}"
    )
  output = process.stdout.strip()
  if not output:
    raise BackendError("Graph token command returned no token")
  try:
    decoded = json.loads(output)
  except json.JSONDecodeError:
    decoded = output
  if isinstance(decoded, dict):
    token = decoded.get("access_token") or decoded.get("token")
    expires_at = decoded.get("expires_at")
  else:
    token = decoded
    expires_at = None
  if not isinstance(token, str) or not token:
    raise BackendError("Graph token command returned no access_token")
  claims_expiry = decode_jwt_payload(token).get("exp")
  if isinstance(expires_at, (int, float)):
    expiry = int(
        expires_at / 1000 if expires_at > 10_000_000_000 else expires_at
    )
  elif isinstance(claims_expiry, (int, float)):
    expiry = int(claims_expiry)
  else:
    expiry = int(time.time()) + 5 * 60
  return token, expiry


def token_from_command(command: list[str]) -> str:
  """Return a cached fresh token from external COMMAND."""
  global TOKEN_COMMAND_CACHE
  if (
      TOKEN_COMMAND_CACHE is not None
      and TOKEN_COMMAND_CACHE[1]
      > time.time() + TOKEN_COMMAND_REFRESH_MARGIN_SECONDS
  ):
    return TOKEN_COMMAND_CACHE[0]
  TOKEN_COMMAND_CACHE = token_command_payload(command)
  return TOKEN_COMMAND_CACHE[0]


def ensure_graph_token(path: Path) -> str:
  """Return a fresh Graph token from the configured external owner."""
  command = resolve_token_command()
  if command:
    return token_from_command(command)
  entry = find_graph_credential(path)
  if entry is not None and graph_token_is_fresh(entry):
    return str(entry["graph_access_token"])

  run_bootstrap(path)
  entry = find_graph_credential(path)
  if entry is None or not graph_token_is_fresh(entry):
    raise BackendError(
        "The credential helper did not produce a fresh graph_access_token "
        f"in {path}"
    )
  return str(entry["graph_access_token"])


def status_payload(path: Path) -> str | dict[str, Any]:
  """Return a CLI-compatible status payload for the configured provider."""
  command = resolve_token_command()
  if command:
    token = ensure_graph_token(path)
    claims = decode_jwt_payload(token)
    connected_as = next(
        (
            claims.get(key)
            for key in ("preferred_username", "upn", "email", "name")
            if isinstance(claims.get(key), str) and claims.get(key)
        ),
        "Microsoft Graph user",
    )
    return {
        "connectionName": f"External token command: {command[0]}",
        "connectedAs": connected_as,
        "userId": claims.get("oid") or claims.get("sub") or "unknown",
        "authType": "ExternalTokenCommand",
        "appTenant": claims.get("tid") or "unknown",
        "appId": claims.get("appid") or claims.get("azp") or "unknown",
        "graphTokenStatus": "fresh",
        "graphExpiresAt": (
            TOKEN_COMMAND_CACHE[1] * 1000 if TOKEN_COMMAND_CACHE else None
        ),
        "credentialFile": None,
    }
  entry = find_graph_credential(path)
  if entry is None or not (
      entry.get("refresh_token") or entry.get("graph_access_token")
  ):
    return "Logged out"

  claims = decode_jwt_payload(
      entry.get("graph_access_token") or entry.get("access_token")
  )
  connected_as = next(
      (
          claims.get(key)
          for key in ("preferred_username", "upn", "unique_name", "email", "name")
          if isinstance(claims.get(key), str) and claims.get(key)
      ),
      "Shared M365 OAuth",
  )
  expires_at = graph_token_expiry_millis(entry)
  if not entry.get("graph_access_token"):
    token_status = "missing"
  elif graph_token_is_fresh(entry):
    token_status = "fresh"
  else:
    token_status = "stale"
  return {
      "connectionName": "Shared Microsoft Graph credential store",
      "connectedAs": connected_as,
      "userId": claims.get("oid") or claims.get("sub") or "unknown",
      "authType": "SharedGraphOAuth",
      "appTenant": claims.get("tid") or entry.get("tenant_id") or "unknown",
      "appId": claims.get("appid") or entry.get("client_id") or "unknown",
      "graphTokenStatus": token_status,
      "graphExpiresAt": expires_at,
      "credentialFile": str(path),
  }


def external_token_payload(path: Path) -> dict[str, Any]:
  """Return the short-lived token envelope consumed by terminal clients."""
  # Concurrent read requests share the credential owner.  Serialize only the
  # refresh check so an expired token cannot launch duplicate bootstrap flows.
  with TOKEN_REFRESH_LOCK:
    access_token = ensure_graph_token(path)
  command = resolve_token_command()
  if command and TOKEN_COMMAND_CACHE and TOKEN_COMMAND_CACHE[0] == access_token:
    expires_at = TOKEN_COMMAND_CACHE[1]
  else:
    entry = find_graph_credential(path)
    if entry is None:
      raise BackendError(f"Graph credential disappeared from {path}")
    expiry_millis = graph_token_expiry_millis(entry)
    expires_at = expiry_millis // 1000 if isinstance(expiry_millis, int) else None
  if not isinstance(expires_at, int):
    raise BackendError("Shared Graph token has no usable expiration time")
  return {
      "access_token": access_token,
      "expires_at": expires_at,
  }


def validate_graph_url(url: str) -> None:
  """Prevent bearer-token forwarding outside Microsoft Graph."""
  parsed = urllib.parse.urlparse(url)
  if parsed.scheme != "https" or parsed.hostname != GRAPH_HOST:
    raise BackendError(f"Refusing non-Graph pagination URL: {url}")


def graph_json(
    path_or_url: str,
    access_token: str,
    *,
    method: str = "GET",
    payload: dict[str, Any] | None = None,
    request_headers: dict[str, str] | None = None,
) -> dict[str, Any]:
  """Make one authenticated Graph request and decode its JSON response."""
  url = path_or_url if path_or_url.startswith("https://") else GRAPH_ROOT + path_or_url
  validate_graph_url(url)
  body = None
  headers = {
      "Accept": "application/json",
      "Authorization": f"Bearer {access_token}",
  }
  if request_headers:
    headers.update(request_headers)
  if payload is not None:
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    headers["Content-Type"] = "application/json"
  response_body = ""
  for attempt in range(GRAPH_RETRY_ATTEMPTS):
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
      with urllib.request.urlopen(request, timeout=60) as response:
        response_body = response.read().decode("utf-8")
      break
    except urllib.error.HTTPError as exception:
      detail = exception.read().decode("utf-8", errors="replace")
      retryable = exception.code in {429, 500, 502, 503, 504}
      if retryable and attempt + 1 < GRAPH_RETRY_ATTEMPTS:
        retry_after = exception.headers.get("Retry-After")
        try:
          delay = float(retry_after) if retry_after else float(2**attempt)
        except ValueError:
          delay = float(2**attempt)
        time.sleep(max(0.0, min(delay, GRAPH_MAX_RETRY_SECONDS)))
        continue
      try:
        error_payload = json.loads(detail)
        error = (
            error_payload.get("error")
            if isinstance(error_payload, dict)
            else None
        )
        if isinstance(error, dict) and isinstance(error.get("message"), str):
          detail = error["message"]
      except json.JSONDecodeError:
        pass
      raise BackendError(
          f"Microsoft Graph HTTP {exception.code}: {detail}"
      ) from exception
    except (OSError, urllib.error.URLError) as exception:
      if attempt + 1 < GRAPH_RETRY_ATTEMPTS:
        time.sleep(float(2**attempt))
        continue
      raise BackendError(
          f"Microsoft Graph request failed after {GRAPH_RETRY_ATTEMPTS} attempts: "
          f"{exception}"
      ) from exception

  if not response_body.strip():
    return {}
  try:
    result = json.loads(response_body)
  except json.JSONDecodeError as exception:
    raise BackendError("Microsoft Graph returned a non-JSON response") from exception
  if not isinstance(result, dict):
    raise BackendError("Microsoft Graph returned an unexpected JSON value")
  return result


def graph_text(
    path_or_url: str,
    access_token: str,
    *,
    accept: str = "text/plain",
) -> str:
  """Make one authenticated Graph request and return decoded text content."""
  url = path_or_url if path_or_url.startswith("https://") else GRAPH_ROOT + path_or_url
  validate_graph_url(url)
  request = urllib.request.Request(
      url,
      headers={"Accept": accept, "Authorization": f"Bearer {access_token}"},
      method="GET",
  )
  for attempt in range(GRAPH_RETRY_ATTEMPTS):
    try:
      with urllib.request.urlopen(request, timeout=60) as response:
        return response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exception:
      detail = exception.read().decode("utf-8", errors="replace")
      retryable = exception.code in {429, 500, 502, 503, 504}
      if retryable and attempt + 1 < GRAPH_RETRY_ATTEMPTS:
        retry_after = exception.headers.get("Retry-After")
        try:
          delay = float(retry_after) if retry_after else float(2**attempt)
        except ValueError:
          delay = float(2**attempt)
        time.sleep(max(0.0, min(delay, GRAPH_MAX_RETRY_SECONDS)))
        continue
      try:
        error_payload = json.loads(detail)
        graph_error = error_payload.get("error", {})
        inner = graph_error.get("innerError", {})
        code = inner.get("code") or graph_error.get("code")
        message = graph_error.get("message")
        detail = ": ".join(str(value) for value in (code, message) if value)
      except (json.JSONDecodeError, AttributeError):
        pass
      raise BackendError(
          f"Microsoft Graph transcript HTTP {exception.code}: {detail}"
      ) from exception
    except (OSError, urllib.error.URLError) as exception:
      if attempt + 1 < GRAPH_RETRY_ATTEMPTS:
        time.sleep(float(2**attempt))
        continue
      raise BackendError(
          "Microsoft Graph transcript request failed after "
          f"{GRAPH_RETRY_ATTEMPTS} attempts: {exception}"
      ) from exception
  raise BackendError("Microsoft Graph transcript request failed")


def graph_upload_file(path: Path, access_token: str) -> dict[str, Any]:
  """Upload PATH to the signed-in user's Teams chat-files folder."""
  path = path.expanduser().resolve()
  if not path.is_file():
    raise BackendError(f"Attachment is not a file: {path}")
  if path.stat().st_size > 250 * 1024 * 1024:
    raise BackendError("Graph simple upload supports attachments up to 250 MB")
  remote_name = f"teams4e-{time.time_ns()}-{path.name}"
  encoded_name = urllib.parse.quote(remote_name, safe="")
  url = (
      f"{GRAPH_ROOT}/me/drive/root:/Microsoft%20Teams%20Chat%20Files/"
      f"{encoded_name}:/content"
  )
  validate_graph_url(url)
  headers = {
      "Accept": "application/json",
      "Authorization": f"Bearer {access_token}",
      "Content-Type": "application/octet-stream",
  }
  request = urllib.request.Request(
      url, data=path.read_bytes(), headers=headers, method="PUT"
  )
  try:
    with urllib.request.urlopen(request, timeout=300) as response:
      body = response.read().decode("utf-8")
  except urllib.error.HTTPError as exception:
    detail = exception.read().decode("utf-8", errors="replace")
    raise BackendError(
        f"Microsoft Graph attachment upload HTTP {exception.code}: {detail}"
    ) from exception
  except (OSError, urllib.error.URLError) as exception:
    raise BackendError(f"Microsoft Graph attachment upload failed: {exception}") from exception
  try:
    value = json.loads(body)
  except json.JSONDecodeError as exception:
    raise BackendError("Microsoft Graph upload returned non-JSON data") from exception
  if not isinstance(value, dict) or not isinstance(value.get("id"), str):
    raise BackendError("Microsoft Graph upload returned no drive item ID")
  return value


class _NoRedirect(urllib.request.HTTPRedirectHandler):
  """Expose Graph download redirects so bearer headers are not forwarded."""

  def redirect_request(
      self,
      req: urllib.request.Request,
      fp: Any,
      code: int,
      msg: str,
      headers: Any,
      newurl: str,
  ) -> None:
    del req, fp, code, msg, headers, newurl
    return None


def _share_id(url: str) -> str:
  encoded = base64.urlsafe_b64encode(url.encode("utf-8")).decode("ascii")
  return "u!" + encoded.rstrip("=")


def download_graph_content(
    graph_url: str, destination: Path, access_token: str
) -> dict[str, Any]:
  """Download a Graph-hosted binary while stripping auth on redirects."""
  validate_graph_url(graph_url)
  request = urllib.request.Request(
      graph_url,
      headers={"Authorization": f"Bearer {access_token}"},
      method="GET",
  )
  opener = urllib.request.build_opener(_NoRedirect)
  content_type: str | None = None
  try:
    with opener.open(request, timeout=300) as response:
      content = response.read()
      content_type = response.headers.get_content_type()
  except urllib.error.HTTPError as exception:
    if exception.code not in {301, 302, 303, 307, 308}:
      detail = exception.read().decode("utf-8", errors="replace")
      raise BackendError(
          f"Microsoft Graph content download HTTP {exception.code}: {detail}"
      ) from exception
    location = exception.headers.get("Location")
    if not isinstance(location, str) or not location.startswith("https://"):
      raise BackendError("Graph returned an invalid content redirect") from exception
    try:
      with urllib.request.urlopen(location, timeout=300) as response:
        content = response.read()
        content_type = response.headers.get_content_type()
    except (OSError, urllib.error.URLError) as redirect_exception:
      raise BackendError(
          f"Graph content redirect failed: {redirect_exception}"
      ) from redirect_exception
  except (OSError, urllib.error.URLError) as exception:
    raise BackendError(f"Microsoft Graph content download failed: {exception}") from exception
  destination = destination.expanduser()
  destination.parent.mkdir(parents=True, exist_ok=True)
  destination.write_bytes(content)
  try:
    destination.chmod(0o600)
  except OSError:
    pass
  return {
      "path": str(destination),
      "bytes": len(content),
      "contentType": content_type,
  }


def download_reference_attachment(
    content_url: str,
    destination: Path,
    access_token: str,
) -> dict[str, Any]:
  """Download a Teams reference attachment without leaking ACCESS_TOKEN."""
  if not content_url.startswith("https://"):
    raise BackendError("Production attachment URLs must use HTTPS")
  parsed = urllib.parse.urlparse(content_url)
  if parsed.hostname == GRAPH_HOST:
    return download_graph_content(content_url, destination, access_token)
  drive_item = graph_json(
      f"/shares/{quoted_id(_share_id(content_url))}/driveItem"
      "?$select=id,name,size,parentReference",
      access_token,
  )
  item_id = drive_item.get("id")
  parent = drive_item.get("parentReference")
  drive_id = parent.get("driveId") if isinstance(parent, dict) else None
  if not isinstance(item_id, str) or not isinstance(drive_id, str):
    raise BackendError("Cannot resolve the Teams attachment to a drive item")
  graph_url = (
      f"{GRAPH_ROOT}/drives/{quoted_id(drive_id)}/items/{quoted_id(item_id)}/content"
  )
  validate_graph_url(graph_url)
  request = urllib.request.Request(
      graph_url,
      headers={"Authorization": f"Bearer {access_token}"},
      method="GET",
  )
  opener = urllib.request.build_opener(_NoRedirect)
  location: str | None = None
  try:
    with opener.open(request, timeout=60) as response:
      content = response.read()
  except urllib.error.HTTPError as exception:
    if exception.code not in {301, 302, 303, 307, 308}:
      detail = exception.read().decode("utf-8", errors="replace")
      raise BackendError(
          f"Microsoft Graph attachment download HTTP {exception.code}: {detail}"
      ) from exception
    location = exception.headers.get("Location")
    if not isinstance(location, str) or not location.startswith("https://"):
      raise BackendError("Graph returned an invalid attachment redirect") from exception
    try:
      with urllib.request.urlopen(location, timeout=300) as response:
        content = response.read()
    except (OSError, urllib.error.URLError) as redirect_exception:
      raise BackendError(
          f"Attachment content download failed: {redirect_exception}"
      ) from redirect_exception
  except (OSError, urllib.error.URLError) as exception:
    raise BackendError(f"Microsoft Graph attachment download failed: {exception}") from exception
  destination = destination.expanduser()
  destination.parent.mkdir(parents=True, exist_ok=True)
  destination.write_bytes(content)
  try:
    destination.chmod(0o600)
  except OSError:
    pass
  return {
      "path": str(destination),
      "bytes": len(content),
      "name": drive_item.get("name"),
  }


def graph_collection(
    path_or_url: str,
    access_token: str,
    *,
    limit: int | None = None,
) -> list[dict[str, Any]]:
  """Read Graph collection pages, stopping after optional LIMIT items."""
  items: list[dict[str, Any]] = []
  next_url: str | None = path_or_url
  seen_urls: set[str] = set()
  while next_url and (limit is None or len(items) < limit):
    if next_url in seen_urls:
      raise BackendError("Microsoft Graph pagination repeated a page URL")
    seen_urls.add(next_url)
    page = graph_json(next_url, access_token)
    values = page.get("value", [])
    if not isinstance(values, list):
      raise BackendError("Microsoft Graph collection has no value array")
    items.extend(item for item in values if isinstance(item, dict))
    candidate = page.get("@odata.nextLink")
    next_url = candidate if isinstance(candidate, str) and candidate else None
  return items if limit is None else items[:limit]


def collection_path(path: str, parameters: list[tuple[str, str]]) -> str:
  """Attach encoded OData PARAMETERS to PATH."""
  return f"{path}?{urllib.parse.urlencode(parameters)}"


def quoted_id(value: str) -> str:
  """Quote an opaque Graph resource ID for a URL path segment."""
  return urllib.parse.quote(value, safe="")


def list_chats(
    access_token: str, metadata_limit: int | None = None
) -> list[dict[str, Any]]:
  """Return chats, including the preview needed by the native inbox."""
  return graph_collection(
      collection_path(
          "/me/chats",
          [("$top", "50"), ("$expand", "lastMessagePreview")],
      ),
      access_token,
      limit=metadata_limit,
  )


def list_members(chat_id: str, access_token: str) -> list[dict[str, Any]]:
  """Return members of CHAT_ID."""
  return graph_collection(f"/chats/{quoted_id(chat_id)}/members", access_token)


def get_calendar_event(event_id: str, access_token: str) -> dict[str, Any]:
  """Return schedule, location, response, and join metadata for EVENT_ID."""
  event_path = collection_path(
      f"/me/events/{quoted_id(event_id)}",
      [("$select", MEETING_EVENT_SELECT)],
  )
  return graph_json(
      event_path,
      access_token,
      request_headers={"Prefer": 'outlook.timezone="UTC"'},
  )


def parse_graph_datetime(value: str) -> datetime:
  """Parse a Graph/CLI date-time VALUE and normalize it to UTC."""
  if not isinstance(value, str) or not value.strip():
    raise BackendError("Meeting time must be a nonempty ISO 8601 date-time")
  normalized = value.strip()
  if normalized.endswith("Z"):
    normalized = normalized[:-1] + "+00:00"
  try:
    parsed = datetime.fromisoformat(normalized)
  except ValueError as exception:
    raise BackendError(f"Invalid meeting date-time: {value}") from exception
  if parsed.tzinfo is None:
    parsed = parsed.replace(tzinfo=timezone.utc)
  return parsed.astimezone(timezone.utc)


def graph_utc_date_time(value: str) -> dict[str, str]:
  """Return Graph dateTimeTimeZone JSON for ISO date-time VALUE in UTC."""
  parsed = parse_graph_datetime(value)
  return {
      "dateTime": parsed.strftime("%Y-%m-%dT%H:%M:%S"),
      "timeZone": "UTC",
  }


def meeting_duration_iso(event: dict[str, Any]) -> str:
  """Return EVENT duration using the ISO 8601 form expected by Graph."""
  start = event.get("start") if isinstance(event.get("start"), dict) else {}
  end = event.get("end") if isinstance(event.get("end"), dict) else {}
  start_value = start.get("dateTime")
  end_value = end.get("dateTime")
  if not isinstance(start_value, str) or not isinstance(end_value, str):
    raise BackendError("The linked meeting has no usable start/end time")
  seconds = int(
      (parse_graph_datetime(end_value) - parse_graph_datetime(start_value)).total_seconds()
  )
  if seconds <= 0:
    raise BackendError("The linked meeting has an invalid duration")
  hours, remainder = divmod(seconds, 3600)
  minutes, seconds = divmod(remainder, 60)
  parts = ["PT"]
  if hours:
    parts.append(f"{hours}H")
  if minutes:
    parts.append(f"{minutes}M")
  if seconds:
    parts.append(f"{seconds}S")
  return "".join(parts)


def meeting_suggestion_attendees(
    event: dict[str, Any], profile: dict[str, Any]
) -> list[dict[str, Any]]:
  """Return de-duplicated non-self attendees for findMeetingTimes."""
  self_addresses = {
      str(profile.get(key)).casefold()
      for key in ("mail", "userPrincipalName")
      if isinstance(profile.get(key), str) and profile.get(key)
  }
  people: list[dict[str, Any]] = []
  organizer = event.get("organizer")
  if isinstance(organizer, dict):
    people.append({"type": "required", **organizer})
  attendees = event.get("attendees")
  if isinstance(attendees, list):
    people.extend(item for item in attendees if isinstance(item, dict))
  result: list[dict[str, Any]] = []
  seen: set[str] = set()
  for person in people:
    email = person.get("emailAddress")
    email = email if isinstance(email, dict) else {}
    address = email.get("address")
    if not isinstance(address, str) or not address.strip():
      continue
    key = address.casefold()
    if key in self_addresses or key in seen:
      continue
    seen.add(key)
    # findMeetingTimes treats every person as required; only resources retain
    # a distinct request type, regardless of the source event attendee role.
    attendee_type = "resource" if person.get("type") == "resource" else "required"
    result.append({
        "type": attendee_type,
        "emailAddress": {
            "address": address,
            "name": email.get("name") or address,
        },
    })
  return result


def meeting_profile(access_token: str) -> dict[str, Any]:
  """Return the signed-in identity fields used by meeting workflows."""
  return graph_json(
      "/me?$select=displayName,mail,userPrincipalName", access_token
  )


def validate_new_time_proposal(event: dict[str, Any]) -> None:
  """Reject EVENT when the signed-in user cannot propose another time."""
  if event.get("isCancelled"):
    raise BackendError("Cannot propose a new time for a cancelled meeting")
  if event.get("isOrganizer"):
    raise BackendError(
        "You organize this meeting; proposing a new time is an attendee action"
    )
  if event.get("allowNewTimeProposals") is False:
    raise BackendError("The organizer does not allow new time proposals")


def find_meeting_time_suggestions(
    event: dict[str, Any],
    profile: dict[str, Any],
    search_start: str,
    search_end: str,
    access_token: str,
    *,
    max_candidates: int = 8,
    minimum_confidence: int = 50,
    activity_domain: str = "work",
) -> dict[str, Any]:
  """Return availability-ranked alternate times for EVENT and PROFILE."""
  if activity_domain not in {"work", "personal", "unrestricted"}:
    raise BackendError(f"Unsupported meeting activity domain: {activity_domain}")
  search_start_value = graph_utc_date_time(search_start)
  search_end_value = graph_utc_date_time(search_end)
  if parse_graph_datetime(search_end) <= parse_graph_datetime(search_start):
    raise BackendError("Meeting suggestion search must end after it starts")
  payload = {
      "attendees": meeting_suggestion_attendees(event, profile),
      "timeConstraint": {
          "activityDomain": activity_domain,
          "timeSlots": [{"start": search_start_value, "end": search_end_value}],
      },
      "isOrganizerOptional": False,
      "meetingDuration": meeting_duration_iso(event),
      "returnSuggestionReasons": True,
      "minimumAttendeePercentage": max(0, min(minimum_confidence, 100)),
      "maxCandidates": max(1, min(max_candidates, 50)),
  }
  try:
    suggestions = graph_json(
        "/me/findMeetingTimes",
        access_token,
        method="POST",
        payload=payload,
        request_headers={"Prefer": 'outlook.timezone="UTC"'},
    )
  except BackendError as exception:
    return {
        "suggestions": [],
        "suggestionError": str(exception),
        "search": {
            "start": search_start_value,
            "end": search_end_value,
            "activityDomain": activity_domain,
        },
    }
  result = suggestions.get("meetingTimeSuggestions")
  return {
      "suggestions": result if isinstance(result, list) else [],
      "emptySuggestionsReason": suggestions.get("emptySuggestionsReason"),
      "search": {
          "start": search_start_value,
          "end": search_end_value,
          "activityDomain": activity_domain,
      },
  }


def get_meeting_time_suggestions(
    event_id: str,
    search_start: str,
    search_end: str,
    access_token: str,
    *,
    max_candidates: int = 8,
    minimum_confidence: int = 50,
    activity_domain: str = "work",
) -> dict[str, Any]:
  """Return availability-ranked alternate times for linked EVENT_ID."""
  event = get_calendar_event(event_id, access_token)
  validate_new_time_proposal(event)
  profile = meeting_profile(access_token)
  result = find_meeting_time_suggestions(
      event,
      profile,
      search_start,
      search_end,
      access_token,
      max_candidates=max_candidates,
      minimum_confidence=minimum_confidence,
      activity_domain=activity_domain,
  )
  return {"event": event, **result}


def meeting_schedule_participants(
    event: dict[str, Any], profile: dict[str, Any]
) -> list[dict[str, Any]]:
  """Return de-duplicated event participants with the current account first."""
  self_addresses = {
      str(profile.get(key)).casefold()
      for key in ("mail", "userPrincipalName")
      if isinstance(profile.get(key), str) and profile.get(key)
  }
  records: dict[str, dict[str, Any]] = {}
  order: list[str] = []

  def add(contact: dict[str, Any], *, organizer: bool = False) -> None:
    email = contact.get("emailAddress")
    email = email if isinstance(email, dict) else {}
    address = email.get("address")
    if not isinstance(address, str) or not address.strip():
      return
    key = address.casefold()
    status = contact.get("status")
    status = status if isinstance(status, dict) else {}
    if key not in records:
      order.append(key)
      records[key] = {
          "email": address,
          "name": email.get("name") or address,
          "type": contact.get("type") or "required",
          "isSelf": key in self_addresses,
          "isOrganizer": organizer,
          "response": status.get("response"),
      }
    else:
      record = records[key]
      record["isOrganizer"] = bool(record.get("isOrganizer") or organizer)
      record["isSelf"] = bool(record.get("isSelf") or key in self_addresses)
      if not record.get("response"):
        record["response"] = status.get("response")

  organizer = event.get("organizer")
  if isinstance(organizer, dict):
    add({"type": "required", **organizer}, organizer=True)
  attendees = event.get("attendees")
  if isinstance(attendees, list):
    for attendee in attendees:
      if isinstance(attendee, dict):
        add(attendee)

  self_address = next(
      (
          str(profile.get(key))
          for key in ("mail", "userPrincipalName")
          if isinstance(profile.get(key), str) and profile.get(key)
      ),
      None,
  )
  if self_address and self_address.casefold() not in records:
    key = self_address.casefold()
    order.append(key)
    response = event.get("responseStatus")
    response = response if isinstance(response, dict) else {}
    records[key] = {
        "email": self_address,
        "name": profile.get("displayName") or self_address,
        "type": "required",
        "isSelf": True,
        "isOrganizer": bool(event.get("isOrganizer")),
        "response": response.get("response"),
    }
  for record in records.values():
    if record.get("isSelf") and not record.get("response"):
      response = event.get("responseStatus")
      response = response if isinstance(response, dict) else {}
      record["response"] = response.get("response")
  order_index = {key: index for index, key in enumerate(order)}
  return [
      records[key]
      for key in sorted(
          order,
          key=lambda item: (
              not bool(records[item].get("isSelf")),
              not bool(records[item].get("isOrganizer")),
              order_index[item],
          ),
      )
  ]


def get_schedule_batch(
    addresses: list[str],
    search_start: str,
    search_end: str,
    interval_minutes: int,
    access_token: str,
) -> list[dict[str, Any]]:
  """Return one Graph getSchedule batch for ADDRESSES."""
  result = graph_json(
      "/me/calendar/getSchedule",
      access_token,
      method="POST",
      payload={
          "schedules": addresses,
          "startTime": graph_utc_date_time(search_start),
          "endTime": graph_utc_date_time(search_end),
          "availabilityViewInterval": interval_minutes,
      },
      request_headers={"Prefer": 'outlook.timezone="UTC"'},
  )
  value = result.get("value")
  return (
      [item for item in value if isinstance(item, dict)]
      if isinstance(value, list)
      else []
  )


def get_meeting_schedules(
    participants: list[dict[str, Any]],
    search_start: str,
    search_end: str,
    interval_minutes: int,
    access_token: str,
) -> tuple[list[dict[str, Any]], list[str]]:
  """Return free/busy schedules for PARTICIPANTS in bounded Graph batches."""
  addresses = [
      str(participant["email"])
      for participant in participants
      if isinstance(participant.get("email"), str) and participant.get("email")
  ]
  batches = [
      addresses[index:index + GET_SCHEDULE_BATCH_LIMIT]
      for index in range(0, len(addresses), GET_SCHEDULE_BATCH_LIMIT)
  ]
  if not batches:
    return [], []
  records: list[dict[str, Any]] = []
  errors: list[str] = []
  workers = min(3, len(batches))
  with ThreadPoolExecutor(max_workers=workers) as executor:
    futures = {
        executor.submit(
            get_schedule_batch,
            batch,
            search_start,
            search_end,
            interval_minutes,
            access_token,
        ): batch
        for batch in batches
    }
    for future in as_completed(futures):
      batch = futures[future]
      try:
        records.extend(future.result())
      except BackendError as exception:
        detail = str(exception)
        errors.append(detail)
        records.extend(
            {"scheduleId": address, "error": {"message": detail}}
            for address in batch
        )
  by_address = {
      str(record.get("scheduleId")).casefold(): record
      for record in records
      if isinstance(record.get("scheduleId"), str)
  }
  for record in records:
    error = record.get("error")
    message = error.get("message") if isinstance(error, dict) else None
    if isinstance(message, str) and message and message not in errors:
      errors.append(message)
  return [
      by_address.get(
          address.casefold(),
          {"scheduleId": address, "error": {"message": "No schedule returned"}},
      )
      for address in addresses
  ], errors


def get_meeting_availability(
    event_id: str,
    search_start: str,
    search_end: str,
    access_token: str,
    *,
    max_candidates: int = 8,
    minimum_confidence: int = 50,
    activity_domain: str = "work",
    interval_minutes: int = 30,
) -> dict[str, Any]:
  """Return ranked times and participant calendar blocks for EVENT_ID."""
  event = get_calendar_event(event_id, access_token)
  start_time = parse_graph_datetime(search_start)
  end_time = parse_graph_datetime(search_end)
  if end_time <= start_time:
    raise BackendError("Meeting availability search must end after it starts")
  if (end_time - start_time).total_seconds() >= 62 * 24 * 60 * 60:
    raise BackendError("Meeting availability searches must be shorter than 62 days")
  profile = meeting_profile(access_token)
  participants = meeting_schedule_participants(event, profile)
  suggestions = find_meeting_time_suggestions(
      event,
      profile,
      search_start,
      search_end,
      access_token,
      max_candidates=max_candidates,
      minimum_confidence=minimum_confidence,
      activity_domain=activity_domain,
  )
  schedules, schedule_errors = get_meeting_schedules(
      participants,
      search_start,
      search_end,
      max(5, min(interval_minutes, 1440)),
      access_token,
  )
  proposal_reason = None
  if event.get("isCancelled"):
    proposal_reason = "This meeting is cancelled"
  elif event.get("isOrganizer"):
    proposal_reason = "You organize this meeting; use the calendar event to reschedule"
  elif event.get("allowNewTimeProposals") is False:
    proposal_reason = "The organizer does not allow new time proposals"
  return {
      "event": event,
      "profile": profile,
      "participants": participants,
      "schedules": schedules,
      "scheduleError": "; ".join(dict.fromkeys(schedule_errors)) or None,
      "proposalAllowed": proposal_reason is None,
      "proposalUnavailableReason": proposal_reason,
      **suggestions,
  }


def respond_to_meeting(
    event_id: str,
    response: str,
    comment: str,
    access_token: str,
) -> dict[str, Any]:
  """Accept, tentatively accept, or decline EVENT_ID and notify its organizer."""
  actions = {
      "accepted": "accept",
      "tentativelyAccepted": "tentativelyAccept",
      "declined": "decline",
  }
  if response not in actions:
    raise BackendError(f"Unsupported meeting response: {response}")
  event = get_calendar_event(event_id, access_token)
  if event.get("isCancelled"):
    raise BackendError("Cannot respond to a cancelled meeting")
  if event.get("isOrganizer"):
    raise BackendError("The meeting organizer cannot RSVP as an attendee")
  graph_json(
      f"/me/events/{quoted_id(event_id)}/{actions[response]}",
      access_token,
      method="POST",
      payload={"comment": comment, "sendResponse": True},
  )
  event["responseStatus"] = {
      "response": response,
      "time": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
  }
  return {"status": "responded", "response": response, "event": event}


def propose_new_meeting_time(
    event_id: str,
    start: str,
    end: str,
    comment: str,
    access_token: str,
) -> dict[str, Any]:
  """Tentatively accept EVENT_ID while proposing alternate START and END."""
  event = get_calendar_event(event_id, access_token)
  validate_new_time_proposal(event)
  if parse_graph_datetime(end) <= parse_graph_datetime(start):
    raise BackendError("Proposed meeting end must be after its start")
  proposal = {
      "start": graph_utc_date_time(start),
      "end": graph_utc_date_time(end),
  }
  graph_json(
      f"/me/events/{quoted_id(event_id)}/tentativelyAccept",
      access_token,
      method="POST",
      payload={
          "comment": comment,
          "sendResponse": True,
          "proposedNewTime": proposal,
      },
  )
  event["responseStatus"] = {
      "response": "tentativelyAccepted",
      "time": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
  }
  return {
      "status": "proposed",
      "eventId": event_id,
      "event": event,
      "proposal": proposal,
  }


def get_meeting_context(chat_id: str, access_token: str) -> dict[str, Any]:
  """Return calendar timing and participants for meeting CHAT_ID.

  Chat metadata exposes a calendar event ID but not the meeting start/end time.
  Event lookup is best effort so Chat.Read users still receive participants
  when the shared token lacks Calendars.ReadBasic or Calendars.Read.
  """
  chat = graph_json(f"/chats/{quoted_id(chat_id)}", access_token)
  if chat.get("chatType") != "meeting":
    raise BackendError("Meeting context requires a meeting chat")
  members = list_members(chat_id, access_token)
  meeting_info = chat.get("onlineMeetingInfo")
  meeting_info = meeting_info if isinstance(meeting_info, dict) else {}
  event_id = meeting_info.get("calendarEventId")
  result: dict[str, Any] = {
      "chatId": chat_id,
      "members": members,
      "membersLoaded": True,
      "onlineMeetingInfo": meeting_info,
  }
  if not isinstance(event_id, str) or not event_id:
    result["eventError"] = "The meeting chat has no linked calendar event ID"
    return result
  try:
    result["event"] = get_calendar_event(event_id, access_token)
  except BackendError as exception:
    result["eventError"] = str(exception)
  return result


def meeting_event_record(
    chat_id: str,
    event_id: str | None,
    access_token: str,
) -> dict[str, Any]:
  """Resolve one meeting event, looking up omitted chat metadata if needed."""
  result: dict[str, Any] = {"chatId": chat_id}
  if not event_id:
    try:
      chat = graph_json(f"/chats/{quoted_id(chat_id)}", access_token)
    except BackendError as exception:
      result["eventError"] = str(exception)
      return result
    if chat.get("chatType") != "meeting":
      result["eventError"] = "The chat is not a meeting conversation"
      return result
    meeting_info = chat.get("onlineMeetingInfo")
    meeting_info = meeting_info if isinstance(meeting_info, dict) else {}
    result["onlineMeetingInfo"] = meeting_info
    candidate = meeting_info.get("calendarEventId")
    event_id = candidate if isinstance(candidate, str) and candidate else None
  if not event_id:
    result["eventError"] = "The meeting chat has no linked calendar event ID"
    return result
  try:
    result["event"] = get_calendar_event(event_id, access_token)
  except BackendError as exception:
    result["eventError"] = str(exception)
  return result


def list_meeting_events_batch(
    meetings: list[dict[str, Any]],
    access_token: str,
    *,
    meeting_concurrency: int = 6,
) -> list[dict[str, Any]]:
  """Resolve linked events for MEETINGS using bounded concurrency.

  Inputs may include an eventId already present in the chat-list response.  A
  missing eventId costs one bounded chat metadata request, but never loads
  members or messages.  This keeps ordinary inbox enrichment cheap while
  allowing the explicit meeting workspace to resolve otherwise sparse rows.
  """
  unique: dict[str, str | None] = {}
  for meeting in meetings:
    chat_id = meeting.get("chatId")
    event_id = meeting.get("eventId")
    if not isinstance(chat_id, str) or not chat_id:
      continue
    normalized_event_id = (
        event_id if isinstance(event_id, str) and event_id else None
    )
    if chat_id not in unique or normalized_event_id:
      unique[chat_id] = normalized_event_id
  if not unique:
    return []
  workers = max(1, min(meeting_concurrency, len(unique)))
  records: dict[str, dict[str, Any]] = {}
  with ThreadPoolExecutor(max_workers=workers) as executor:
    futures = {
        executor.submit(
            meeting_event_record, chat_id, event_id, access_token
        ): chat_id
        for chat_id, event_id in unique.items()
    }
    for future in as_completed(futures):
      chat_id = futures[future]
      records[chat_id] = future.result()
  return [records[chat_id] for chat_id in unique]


def get_meeting_transcript(chat_id: str, access_token: str) -> dict[str, Any]:
  """Return the latest available transcript for meeting CHAT_ID."""
  context = get_meeting_context(chat_id, access_token)
  event = context.get("event")
  event = event if isinstance(event, dict) else {}
  event_meeting = event.get("onlineMeeting")
  event_meeting = event_meeting if isinstance(event_meeting, dict) else {}
  meeting_info = context.get("onlineMeetingInfo")
  meeting_info = meeting_info if isinstance(meeting_info, dict) else {}
  join_url = event_meeting.get("joinUrl") or meeting_info.get("joinWebUrl")
  if not isinstance(join_url, str) or not join_url:
    raise BackendError("The meeting chat has no join URL for transcript lookup")
  escaped_url = join_url.replace("'", "''")
  meeting_page = graph_json(
      collection_path(
          "/me/onlineMeetings",
          [("$filter", f"JoinWebUrl eq '{escaped_url}'")],
      ),
      access_token,
  )
  meetings = meeting_page.get("value", [])
  meetings = meetings if isinstance(meetings, list) else []
  meeting = next((item for item in meetings if isinstance(item, dict)), None)
  if meeting is None or not isinstance(meeting.get("id"), str):
    raise BackendError("Microsoft Graph could not resolve the meeting join URL")
  meeting_id = str(meeting["id"])
  transcripts = graph_collection(
      f"/me/onlineMeetings/{quoted_id(meeting_id)}/transcripts",
      access_token,
  )
  if not transcripts:
    raise BackendError("No transcript is available for this meeting")
  transcript = max(
      transcripts,
      key=lambda item: str(
          item.get("endDateTime") or item.get("createdDateTime") or ""
      ),
  )
  transcript_id = transcript.get("id")
  if not isinstance(transcript_id, str) or not transcript_id:
    raise BackendError("Microsoft Graph returned a transcript without an ID")
  content_path = (
      f"/me/onlineMeetings/{quoted_id(meeting_id)}/transcripts/"
      f"{quoted_id(transcript_id)}/content"
  )
  content_type = "text/vtt"
  try:
    content = graph_text(content_path, access_token, accept=content_type)
  except BackendError as exception:
    if "SpeakerAttributionNotAllowed" not in str(exception):
      raise
    content_type = "application/vnd.microsoft.graph.transcript+text"
    content = graph_text(content_path, access_token, accept=content_type)
  return {
      "chatId": chat_id,
      "meeting": meeting,
      "event": event,
      "transcript": transcript,
      "contentType": content_type,
      "content": content,
  }


def list_chat_members_batch(
    chat_ids: list[str],
    access_token: str,
    *,
    member_concurrency: int = 8,
) -> list[dict[str, Any]]:
  """Return member records for CHAT_IDS using bounded concurrency.

  teams-tui-go makes the same per-chat Graph calls concurrently in its
  long-lived process.  This command gives Emacs equivalent transport without
  starting one Python interpreter per chat or blocking initial metadata rows.
  """
  unique_ids = list(dict.fromkeys(chat_id for chat_id in chat_ids if chat_id))
  if not unique_ids:
    return []
  workers = max(1, min(member_concurrency, len(unique_ids)))
  records: dict[str, dict[str, Any]] = {}
  with ThreadPoolExecutor(max_workers=workers) as executor:
    futures = {
        executor.submit(list_members, chat_id, access_token): chat_id
        for chat_id in unique_ids
    }
    for future in as_completed(futures):
      chat_id = futures[future]
      try:
        records[chat_id] = {
            "chatId": chat_id,
            "members": future.result(),
            "membersLoaded": True,
        }
      except BackendError:
        records[chat_id] = {"chatId": chat_id, "membersLoaded": False}
  return [records[chat_id] for chat_id in unique_ids]


def list_messages(
    chat_id: str,
    access_token: str,
    modified_start: str | None = None,
    limit: int | None = None,
) -> list[dict[str, Any]]:
  """Return all selected messages for CHAT_ID, newest pages first."""
  parameters = [
      ("$top", "50"),
      ("$orderby", "lastModifiedDateTime desc"),
  ]
  if modified_start:
    parameters.append(
        ("$filter", f"lastModifiedDateTime gt {modified_start}")
    )
  path = collection_path(
      f"/chats/{quoted_id(chat_id)}/messages", parameters
  )
  return graph_collection(path, access_token, limit=limit)


def list_joined_teams(access_token: str) -> list[dict[str, Any]]:
  """Return teams joined by the signed-in user."""
  return graph_collection(
      collection_path(
          "/me/joinedTeams",
          [("$select", "id,displayName,description,visibility,webUrl")],
      ),
      access_token,
  )


def list_channels(team_id: str, access_token: str) -> list[dict[str, Any]]:
  """Return visible channels in TEAM_ID."""
  return graph_collection(
      collection_path(
          f"/teams/{quoted_id(team_id)}/channels",
          [
              (
                  "$select",
                  "id,displayName,description,membershipType,webUrl",
              )
          ],
      ),
      access_token,
  )


def list_channel_messages(
    team_id: str, channel_id: str, access_token: str
) -> list[dict[str, Any]]:
  """Return every root message in one channel."""
  return graph_collection(
      collection_path(
          f"/teams/{quoted_id(team_id)}/channels/{quoted_id(channel_id)}/messages",
          [("$top", "50"), ("$expand", "replies")],
      ),
      access_token,
  )


def expanded_channel_replies(
    root: dict[str, Any], access_token: str
) -> list[dict[str, Any]]:
  """Return expanded replies for ROOT, following its nested next link."""
  replies = root.get("replies", [])
  result = [reply for reply in replies if isinstance(reply, dict)] \
      if isinstance(replies, list) else []
  next_url = root.get("replies@odata.nextLink")
  if isinstance(next_url, str) and next_url:
    result.extend(graph_collection(next_url, access_token))
  return result


def list_channel_replies(
    team_id: str,
    channel_id: str,
    message_id: str,
    access_token: str,
) -> list[dict[str, Any]]:
  """Return every reply under one root channel MESSAGE_ID."""
  return graph_collection(
      collection_path(
          f"/teams/{quoted_id(team_id)}/channels/{quoted_id(channel_id)}"
          f"/messages/{quoted_id(message_id)}/replies",
          [("$top", "50")],
      ),
      access_token,
  )


def graph_user(user_id: str, access_token: str) -> dict[str, Any]:
  """Return a useful profile for USER_ID or user principal name."""
  fields = (
      "id,displayName,mail,userPrincipalName,jobTitle,officeLocation,"
      "department,businessPhones,mobilePhone"
  )
  return graph_json(
      f"/users/{quoted_id(user_id)}?$select={urllib.parse.quote(fields, safe=',')}",
      access_token,
  )


def search_users(query: str, access_token: str) -> list[dict[str, Any]]:
  """Search the tenant directory by name or email-like identity."""
  query = query.strip()
  if not query:
    raise BackendError("User search query is empty")
  escaped = query.replace('"', '\\"')
  parameters = [
      ("$search", f'"displayName:{escaped}" OR "mail:{escaped}"'),
      (
          "$select",
          "id,displayName,mail,userPrincipalName,jobTitle,officeLocation",
      ),
      ("$top", "50"),
      ("$count", "true"),
  ]
  page = graph_json(
      collection_path("/users", parameters),
      access_token,
      request_headers={"ConsistencyLevel": "eventual"},
  )
  values = page.get("value", [])
  if not isinstance(values, list):
    raise BackendError("Microsoft Graph user search has no value array")
  return [value for value in values if isinstance(value, dict)]


def search_messages(
    query: str,
    access_token: str,
    *,
    offset: int = 0,
    limit: int = 50,
) -> list[dict[str, Any]]:
  """Search Teams messages through Microsoft Search without caching hits."""
  response = graph_json(
      "/search/query",
      access_token,
      method="POST",
      payload={
          "requests": [{
              "entityTypes": ["chatMessage"],
              "query": {"queryString": query},
              "from": offset,
              "size": limit,
          }]
      },
  )
  results: list[dict[str, Any]] = []
  for search_response in response.get("value", []):
    if not isinstance(search_response, dict):
      continue
    for container in search_response.get("hitsContainers", []):
      if not isinstance(container, dict):
        continue
      for hit in container.get("hits", []):
        if not isinstance(hit, dict):
          continue
        resource = hit.get("resource")
        if not isinstance(resource, dict):
          continue
        message = dict(resource)
        channel = message.get("channelIdentity")
        context: dict[str, Any]
        if isinstance(channel, dict) and channel.get("channelId"):
          context = {
              "scopeKind": "channel",
              "scopeId": channel.get("channelId"),
              "teamId": channel.get("teamId"),
              "channelId": channel.get("channelId"),
              "rootMessageId": message.get("replyToId") or message.get("id"),
          }
        else:
          context = {
              "scopeKind": "chat",
              "scopeId": message.get("chatId"),
          }
        context["rank"] = hit.get("rank")
        context["summary"] = hit.get("summary")
        message["searchContext"] = context
        results.append(message)
  return results


def get_presence(user_id: str, access_token: str) -> dict[str, Any]:
  """Return presence for USER_ID."""
  return graph_json(
      f"/users/{quoted_id(user_id)}/presence",
      access_token,
  )


def member_email(member: dict[str, Any]) -> str | None:
  """Return MEMBER's normalized email-like identity when available."""
  for key in ("email", "userPrincipalName"):
    value = member.get(key)
    if isinstance(value, str) and value.strip():
      return value.strip().lower()
  return None


def account_emails(access_token: str) -> set[str]:
  """Return email-like identities represented by ACCESS_TOKEN."""
  claims = decode_jwt_payload(access_token)
  return {
      value.strip().lower()
      for key in ("preferred_username", "upn", "unique_name", "email")
      if isinstance((value := claims.get(key)), str) and value.strip()
  }


def parse_participants(value: str) -> set[str]:
  """Normalize a comma- or semicolon-separated participant list."""
  participants = {
      part.strip().lower()
      for part in value.replace(";", ",").split(",")
      if part.strip()
  }
  if not participants:
    raise BackendError("At least one participant email is required")
  return participants


def find_chat_by_participants(
    participant_text: str, access_token: str
) -> dict[str, Any]:
  """Find an existing chat whose non-current members match participants."""
  wanted = parse_participants(participant_text)
  own_emails = account_emails(access_token)
  chats = list_chats(access_token)
  candidates = [
      chat
      for chat in chats
      if len(wanted) != 1 or chat.get("chatType") == "oneOnOne"
  ]
  for chat in candidates:
    chat_id = chat.get("id")
    if not isinstance(chat_id, str) or not chat_id:
      continue
    members = list_members(chat_id, access_token)
    emails = {email for member in members if (email := member_email(member))}
    others = emails - own_emails
    if others == wanted or (len(wanted) == 1 and wanted <= emails):
      return chat
  participants = ", ".join(sorted(wanted))
  raise BackendError(
      f"No existing Teams chat found for participant(s): {participants}"
  )


def uploaded_reference_attachments(
    attachment_paths: list[str], access_token: str
) -> tuple[list[dict[str, Any]], list[str]]:
  """Upload local paths and return Teams reference attachments and body tags."""
  attachments: list[dict[str, Any]] = []
  tags: list[str] = []
  for attachment_path in attachment_paths:
    local_path = Path(attachment_path).expanduser()
    uploaded = graph_upload_file(local_path, access_token)
    uploaded_id = uploaded.get("id")
    if not isinstance(uploaded_id, str):
      raise BackendError("Uploaded attachment lacks an ID")
    link = graph_json(
        f"/me/drive/items/{quoted_id(uploaded_id)}/createLink",
        access_token,
        method="POST",
        payload={"type": "view", "scope": "organization"},
    )
    link_value = link.get("link") if isinstance(link.get("link"), dict) else {}
    content_url = link_value.get("webUrl") or uploaded.get("webUrl")
    if not isinstance(content_url, str):
      raise BackendError("Uploaded attachment has no shareable web URL")
    attachments.append(
        {
            "id": uploaded_id,
            "contentType": "reference",
            "contentUrl": content_url,
            "name": local_path.name,
        }
    )
    tags.append(
        f'<attachment id="{html.escape(uploaded_id, quote=True)}"></attachment>'
    )
  return attachments, tags


def parse_mention_specs(values: list[str]) -> list[tuple[str, str]]:
  """Parse repeated USER-ID|DISPLAY-NAME mention specifications."""
  mentions: list[tuple[str, str]] = []
  for value in values:
    user_id, separator, display_name = value.partition("|")
    if not separator or not user_id.strip() or not display_name.strip():
      raise BackendError("Mention values must use USER-ID|DISPLAY-NAME")
    mentions.append((user_id.strip(), display_name.strip()))
  return mentions


def outgoing_body(
    message: str,
    *,
    content_type: str,
    mention_specs: list[str],
    attachment_tags: list[str],
) -> tuple[dict[str, str], list[dict[str, Any]]]:
  """Build a Teams body and mention collection."""
  if content_type not in {"text", "html"}:
    raise BackendError("--contentType must be text or html")
  mentions = parse_mention_specs(mention_specs)
  needs_html = bool(attachment_tags or mentions or content_type == "html")
  if not needs_html:
    return {"contentType": "text", "content": message}, []
  content = message if content_type == "html" else html.escape(message).replace("\n", "<br>")
  payload_mentions: list[dict[str, Any]] = []
  for index, (user_id, display_name) in enumerate(mentions):
    literal = f"@{display_name}"
    escaped_literal = literal if content_type == "html" else html.escape(literal)
    tag = f'<at id="{index}">{html.escape(display_name)}</at>'
    if escaped_literal not in content:
      raise BackendError(
          f"Mention placeholder {literal!r} is missing from the message body"
      )
    content = content.replace(escaped_literal, tag, 1)
    payload_mentions.append(
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
  content = "\n".join(attachment_tags + ([content] if content else []))
  return {"contentType": "html", "content": content}, payload_mentions


def send_message(
    chat_id: str,
    message: str,
    access_token: str,
    reply_to_id: str | None = None,
    attachment_paths: list[str] | None = None,
    mention_specs: list[str] | None = None,
    content_type: str = "text",
) -> dict[str, Any]:
  """Send MESSAGE to CHAT_ID, optionally through Graph's quote action."""
  if not message.strip() and not attachment_paths:
    raise BackendError("Message and attachment list are empty")
  attachments, attachment_tags = uploaded_reference_attachments(
      attachment_paths or [], access_token
  )
  body, mentions = outgoing_body(
      message,
      content_type=content_type,
      mention_specs=mention_specs or [],
      attachment_tags=attachment_tags,
  )
  payload: dict[str, Any] = {"body": body}
  if attachments:
    payload["attachments"] = attachments
  if mentions:
    payload["mentions"] = mentions
  if reply_to_id:
    return graph_json(
        f"/chats/{quoted_id(chat_id)}/messages/replyWithQuote",
        access_token,
        method="POST",
        payload={"messageIds": [reply_to_id], "replyMessage": payload},
    )
  return graph_json(
      f"/chats/{quoted_id(chat_id)}/messages",
      access_token,
      method="POST",
      payload=payload,
  )


def send_channel_message(
    team_id: str,
    channel_id: str,
    message: str,
    access_token: str,
    *,
    reply_to_id: str | None = None,
    attachment_paths: list[str] | None = None,
    mention_specs: list[str] | None = None,
    content_type: str = "text",
) -> dict[str, Any]:
  """Send a channel root post or a reply."""
  if not message.strip() and not attachment_paths:
    raise BackendError("Message and attachment list are empty")
  base = (
      f"/teams/{quoted_id(team_id)}/channels/{quoted_id(channel_id)}/messages"
  )
  path = f"{base}/{quoted_id(reply_to_id)}/replies" if reply_to_id else base
  attachments, tags = uploaded_reference_attachments(
      attachment_paths or [], access_token
  )
  body, mentions = outgoing_body(
      message,
      content_type=content_type,
      mention_specs=mention_specs or [],
      attachment_tags=tags,
  )
  payload: dict[str, Any] = {"body": body}
  if attachments:
    payload["attachments"] = attachments
  if mentions:
    payload["mentions"] = mentions
  return graph_json(
      path,
      access_token,
      method="POST",
      payload=payload,
  )


def message_path(
    scope: str,
    *,
    message_id: str,
    chat_id: str | None = None,
    team_id: str | None = None,
    channel_id: str | None = None,
    root_message_id: str | None = None,
) -> str:
  """Return the Graph path for one chat or channel message."""
  if scope == "chat":
    if not chat_id:
      raise BackendError("Chat message operation requires --chatId")
    return f"/chats/{quoted_id(chat_id)}/messages/{quoted_id(message_id)}"
  if scope == "channel":
    if not team_id or not channel_id:
      raise BackendError(
          "Channel message operation requires --teamId and --channelId"
      )
    base = (
        f"/teams/{quoted_id(team_id)}/channels/{quoted_id(channel_id)}"
        f"/messages"
    )
    if root_message_id:
      return (
          f"{base}/{quoted_id(root_message_id)}/replies/{quoted_id(message_id)}"
      )
    return f"{base}/{quoted_id(message_id)}"
  raise BackendError("Message --scope must be chat or channel")


def mutate_message(
    action: str,
    scope: str,
    message_id: str,
    access_token: str,
    *,
    chat_id: str | None = None,
    team_id: str | None = None,
    channel_id: str | None = None,
    root_message_id: str | None = None,
    message: str | None = None,
    reaction: str | None = None,
) -> dict[str, Any]:
  """Edit, soft-delete, set, or unset a message reaction."""
  path = message_path(
      scope,
      message_id=message_id,
      chat_id=chat_id,
      team_id=team_id,
      channel_id=channel_id,
      root_message_id=root_message_id,
  )
  if action == "edit":
    if message is None or not message.strip():
      raise BackendError("Edited message is empty")
    return graph_json(
        path,
        access_token,
        method="PATCH",
        payload={"body": {"contentType": "text", "content": message}},
    )
  if action in {"delete", "restore"}:
    if scope == "chat":
      if not chat_id:
        raise BackendError("Chat message operation requires --chatId")
      user_id, _tenant_id = graph_identity(access_token)
      path = (
          f"/users/{quoted_id(user_id)}/chats/{quoted_id(chat_id)}"
          f"/messages/{quoted_id(message_id)}"
      )
    suffix = "softDelete" if action == "delete" else "undoSoftDelete"
    return graph_json(f"{path}/{suffix}", access_token, method="POST")
  if action in {"react", "unreact"}:
    if not reaction:
      raise BackendError("Reaction is empty")
    suffix = "setReaction" if action == "react" else "unsetReaction"
    return graph_json(
        f"{path}/{suffix}",
        access_token,
        method="POST",
        payload={"reactionType": reaction},
    )
  raise BackendError(f"Unsupported message action: {action}")


def graph_identity(access_token: str) -> tuple[str, str]:
  """Return the signed-in user's object ID and tenant ID from token claims."""
  claims = decode_jwt_payload(access_token)
  user_id = claims.get("oid")
  tenant_id = claims.get("tid")
  if not isinstance(user_id, str) or not user_id:
    profile = graph_json("/me?$select=id", access_token)
    user_id = profile.get("id")
  if not isinstance(tenant_id, str) or not tenant_id:
    organizations = graph_collection("/organization?$select=id", access_token)
    tenant_id = organizations[0].get("id") if organizations else None
  if not isinstance(user_id, str) or not user_id:
    raise BackendError("Cannot determine the signed-in Teams user ID")
  if not isinstance(tenant_id, str) or not tenant_id:
    raise BackendError("Cannot determine the signed-in Teams tenant ID")
  return user_id, tenant_id


def set_chat_read_state(
    chat_id: str, access_token: str, *, unread: bool
) -> dict[str, Any]:
  """Mark CHAT_ID read or unread for the signed-in user."""
  user_id, tenant_id = graph_identity(access_token)
  action = "markChatUnreadForUser" if unread else "markChatReadForUser"
  return graph_json(
      f"/chats/{quoted_id(chat_id)}/{action}",
      access_token,
      method="POST",
      payload={"user": {"id": user_id, "tenantId": tenant_id}},
  )


def resolve_user_ids(identifiers: list[str], access_token: str) -> list[str]:
  """Resolve user IDs or principal names, preserving order and uniqueness."""
  result: list[str] = []
  for identifier in identifiers:
    user = graph_user(identifier.strip(), access_token)
    user_id = user.get("id")
    if not isinstance(user_id, str) or not user_id:
      raise BackendError(f"Cannot resolve Teams user: {identifier}")
    if user_id not in result:
      result.append(user_id)
  return result


def member_payload(user_id: str) -> dict[str, Any]:
  """Return a Graph aadUserConversationMember payload."""
  escaped = user_id.replace("'", "''")
  return {
      "@odata.type": "#microsoft.graph.aadUserConversationMember",
      "roles": ["owner"],
      "user@odata.bind": f"{GRAPH_ROOT}/users('{escaped}')",
  }


def create_chat(
    user_identifiers: list[str],
    access_token: str,
    *,
    topic: str | None = None,
) -> dict[str, Any]:
  """Create a one-to-one or group chat including the signed-in user."""
  if not user_identifiers:
    raise BackendError("Chat creation needs at least one participant")
  me = graph_json("/me?$select=id", access_token)
  me_id = me.get("id")
  if not isinstance(me_id, str) or not me_id:
    raise BackendError("Cannot determine the signed-in user for chat creation")
  user_ids = [me_id] + resolve_user_ids(user_identifiers, access_token)
  user_ids = list(dict.fromkeys(user_ids))
  if len(user_ids) < 2:
    raise BackendError("Chat creation needs another participant")
  chat_type = "oneOnOne" if len(user_ids) == 2 else "group"
  payload: dict[str, Any] = {
      "chatType": chat_type,
      "members": [member_payload(user_id) for user_id in user_ids],
  }
  if chat_type == "group" and topic:
    payload["topic"] = topic
  return graph_json("/chats", access_token, method="POST", payload=payload)


def set_chat_topic(
    chat_id: str, topic: str, access_token: str
) -> dict[str, Any]:
  """Set the topic of a group chat."""
  if not topic.strip():
    raise BackendError("Chat topic is empty")
  return graph_json(
      f"/chats/{quoted_id(chat_id)}",
      access_token,
      method="PATCH",
      payload={"topic": topic},
  )


def add_chat_member(
    chat_id: str, user_identifier: str, access_token: str
) -> dict[str, Any]:
  """Add USER_IDENTIFIER to a group chat."""
  user_ids = resolve_user_ids([user_identifier], access_token)
  return graph_json(
      f"/chats/{quoted_id(chat_id)}/members",
      access_token,
      method="POST",
      payload=member_payload(user_ids[0]),
  )


def remove_chat_member(
    chat_id: str, membership_id: str, access_token: str
) -> dict[str, Any]:
  """Remove opaque MEMBERSHIP_ID from CHAT_ID."""
  return graph_json(
      f"/chats/{quoted_id(chat_id)}/members/{quoted_id(membership_id)}",
      access_token,
      method="DELETE",
  )


def sync_cache(
    access_token: str,
    *,
    scope: str = "chats",
    chat_limit: int = 25,
    days: int = 7,
) -> dict[str, Any]:
  """Poll recent resources into SQLite and report incremental changes."""
  if scope not in {"chats", "all"}:
    raise BackendError("Sync --scope must be chats or all")
  errors: list[dict[str, str]] = []
  sync_started = now_graph_timestamp()
  inserted = 0
  changed = 0
  channel_message_count = 0
  with TeamsCache() as cache:
    had_previous_sync = cache.get_meta("last_sync") is not None
    chats = list_chats(access_token)
    cache.upsert_resources("chat", chats)
    chats = sorted(
        chats,
        key=lambda chat: str(chat.get("lastUpdatedDateTime") or ""),
        reverse=True,
    )[: max(0, chat_limit)]
    modified_start = cache.get_meta("last_sync")
    if not modified_start:
      modified_start = time.strftime(
          "%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - days * 86400)
      )
    for chat in chats:
      chat_id = chat.get("id")
      if not isinstance(chat_id, str):
        continue
      try:
        messages = list_messages(chat_id, access_token, modified_start)
        result = cache.upsert_messages("chat", chat_id, messages)
        inserted += result["inserted"]
        changed += result["changed"]
      except BackendError as exception:
        errors.append({"resource": f"chat:{chat_id}", "error": str(exception)})
    teams: list[dict[str, Any]] = []
    if scope == "all":
      try:
        teams = list_joined_teams(access_token)
        cache.upsert_resources("team", teams)
      except BackendError as exception:
        errors.append({"resource": "teams", "error": str(exception)})
      for team in teams:
        team_id = team.get("id")
        if not isinstance(team_id, str):
          continue
        try:
          channels = list_channels(team_id, access_token)
          cache.upsert_resources("channel", channels, parent_id=team_id)
        except BackendError as exception:
          errors.append({"resource": f"team:{team_id}", "error": str(exception)})
          continue
        for channel in channels:
          channel_id = channel.get("id")
          if not isinstance(channel_id, str):
            continue
          try:
            messages = list_channel_messages(team_id, channel_id, access_token)
            channel_message_count += len(messages)
            result = cache.upsert_messages(
                "channel",
                channel_id,
                messages,
                team_id=team_id,
                channel_id=channel_id,
            )
            inserted += result["inserted"]
            changed += result["changed"]
            for root in messages:
              root_id = root.get("id")
              if not isinstance(root_id, str):
                continue
              replies = expanded_channel_replies(root, access_token)
              result = cache.upsert_messages(
                  "channel",
                  channel_id,
                  replies,
                  team_id=team_id,
                  channel_id=channel_id,
                  root_message_id=root_id,
              )
              inserted += result["inserted"]
              changed += result["changed"]
          except BackendError as exception:
            errors.append(
                {
                    "resource": f"channel:{team_id}/{channel_id}",
                    "error": str(exception),
                }
            )
    # A single global watermark is safe only after every selected resource has
    # succeeded.  Retain the previous value after partial failure so the next
    # run retries the same interval instead of creating a permanent gap.
    if not errors:
      cache.set_meta("last_sync", sync_started)
    cache.connection.commit()
    cache_status = cache.status()
  return {
      "initialized": had_previous_sync,
      "newMessages": inserted if had_previous_sync else 0,
      "changedMessages": changed if had_previous_sync else 0,
      "chats": len(chats),
      "teams": len(teams),
      "channelMessages": channel_message_count,
      "errors": errors,
      "cache": cache_status,
  }


def now_graph_timestamp() -> str:
  """Return the current UTC instant in Graph-compatible form."""
  return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def option(args: list[str], name: str, *, required: bool = True) -> str | None:
  """Return the value after option NAME in ARGS."""
  try:
    value = args[args.index(name) + 1]
  except (ValueError, IndexError):
    if required:
      raise BackendError(f"Missing required option {name}")
    return None
  if not value and required:
    raise BackendError(f"Missing required option {name}")
  return value


def options(args: list[str], name: str) -> list[str]:
  """Return every value following repeated option NAME in ARGS."""
  values: list[str] = []
  index = 0
  while index < len(args):
    if args[index] == name and index + 1 < len(args):
      values.append(args[index + 1])
      index += 2
    else:
      index += 1
  return values


def json_object_list_option(args: list[str], name: str) -> list[dict[str, Any]]:
  """Decode option NAME as a JSON array of objects."""
  raw = str(option(args, name))
  try:
    value = json.loads(raw)
  except json.JSONDecodeError as exception:
    raise BackendError(f"{name} must be valid JSON") from exception
  if not isinstance(value, list) or not all(isinstance(item, dict) for item in value):
    raise BackendError(f"{name} must be a JSON array of objects")
  return value


def integer_option(
    args: list[str], name: str, default: int, *, minimum: int = 0
) -> int:
  """Return bounded integer option NAME or DEFAULT."""
  value = option(args, name, required=False)
  if value is None:
    return default
  try:
    parsed = int(value)
  except ValueError as exception:
    raise BackendError(f"{name} must be an integer") from exception
  if parsed < minimum:
    raise BackendError(f"{name} must be at least {minimum}")
  return parsed


def strip_output_option(args: list[str]) -> tuple[list[str], str]:
  """Remove CLI-compatible --output VALUE and return both results."""
  result: list[str] = []
  output = "json"
  index = 0
  while index < len(args):
    if args[index] == "--output":
      if index + 1 >= len(args):
        raise BackendError("Missing required option value after --output")
      output = args[index + 1]
      index += 2
    else:
      result.append(args[index])
      index += 1
  return result, output


def emit_json(value: Any) -> None:
  """Write VALUE as one JSON document."""
  json.dump(value, sys.stdout, ensure_ascii=False, separators=(",", ":"))
  sys.stdout.write("\n")


def dispatch_cache(args: list[str]) -> Any:
  """Execute a credential-free cache command."""
  with TeamsCache() as cache:
    if args == ["teams", "cache", "status"]:
      return cache.status()
    if args == ["teams", "cache", "clear"]:
      cache.clear()
      return cache.status()
    if args[:3] == ["teams", "cache", "search"]:
      return cache.search(
          str(option(args, "--query")),
          limit=integer_option(args, "--limit", 100, minimum=1),
          scope_kind=option(args, "--scope", required=False),
          scope_id=option(args, "--scopeId", required=False),
      )
    if args == ["teams", "cache", "chat", "list"]:
      return cache.list_resources("chat")
    if args[:5] == ["teams", "cache", "chat", "message", "list"]:
      return cache.list_messages(
          "chat",
          str(option(args, "--chatId")),
          limit=integer_option(args, "--limit", 300, minimum=1),
      )
    if args == ["teams", "cache", "team", "list"]:
      return cache.list_resources("team")
    if args[:4] == ["teams", "cache", "channel", "list"]:
      return cache.list_resources(
          "channel", parent_id=str(option(args, "--teamId"))
      )
    if args[:5] == [
        "teams",
        "cache",
        "channel",
        "message",
        "list",
    ]:
      team_id = str(option(args, "--teamId"))
      channel_id = str(option(args, "--channelId"))
      return cache.list_messages(
          "channel",
          channel_id,
          team_id=team_id,
          channel_id=channel_id,
          root_message_id="",
          limit=integer_option(args, "--limit", 300, minimum=1),
      )
    if args[:5] == [
        "teams",
        "cache",
        "channel",
        "reply",
        "list",
    ]:
      team_id = str(option(args, "--teamId"))
      channel_id = str(option(args, "--channelId"))
      return cache.list_messages(
          "channel",
          channel_id,
          team_id=team_id,
          channel_id=channel_id,
          root_message_id=str(option(args, "--messageId")),
          limit=integer_option(args, "--limit", 300, minimum=1),
      )
  raise BackendError(f"Unsupported cache command: {args!r}")


def execute(raw_args: list[str]) -> tuple[Any, str]:
  """Execute RAW_ARGS and return its result plus requested output mode."""
  args, output = strip_output_option(raw_args)
  path = credentials_path()

  # Cache-only commands never need OAuth and must behave identically while the
  # mock tenant is enabled.  Keep this boundary ahead of backend selection.
  if args[:2] == ["teams", "cache"]:
    return dispatch_cache(args), output

  # External clients receive only the short-lived Graph token. They never read
  # or copy a refresh token owned by the configured provider.
  if args == ["token"]:
    return external_token_payload(path), output

  if mock_enabled():
    try:
      result = MockTenant().execute(args)
    except ValueError as exception:
      raise BackendError(str(exception)) from exception
    return result, output

  if args == ["status"]:
    return status_payload(path), output

  if args == ["login"]:
    if resolve_token_command():
      ensure_graph_token(path)
      return "The external Microsoft Graph token command is ready.", "text"
    run_bootstrap(path, interactive=True)
    entry = find_graph_credential(path)
    if entry is None or not entry.get("graph_access_token"):
      raise BackendError(
          f"Credential bootstrap completed without a Graph token in {path}"
      )
    return "The shared Microsoft Graph credential is ready.", "text"

  with TOKEN_REFRESH_LOCK:
    access_token = ensure_graph_token(path)
  result: Any
  if args[:3] == ["teams", "chat", "list"]:
    result = list_chats(
        access_token,
        integer_option(args, "--metadataLimit", 150, minimum=1),
    )
    with TeamsCache() as cache:
      cache.upsert_resources("chat", result)
  elif args[:3] == ["teams", "search", "messages"]:
    result = search_messages(
        str(option(args, "--query")),
        access_token,
        offset=integer_option(args, "--from", 0, minimum=0),
        limit=integer_option(args, "--limit", 50, minimum=1),
    )
  elif args[:4] == ["teams", "chat", "member", "batch"]:
    result = list_chat_members_batch(
        options(args, "--chatId"),
        access_token,
        member_concurrency=integer_option(
            args, "--memberConcurrency", 8, minimum=1
        ),
    )
    with TeamsCache() as cache:
      for record in result:
        if record.get("membersLoaded"):
          cache.upsert_resources(
              "member",
              record.get("members") or [],
              parent_id=str(record.get("chatId") or ""),
          )
  elif args[:4] == ["teams", "meeting", "event", "batch"]:
    result = list_meeting_events_batch(
        json_object_list_option(args, "--meetings"),
        access_token,
        meeting_concurrency=integer_option(
            args, "--meetingConcurrency", 6, minimum=1
        ),
    )
  elif args[:4] == ["teams", "meeting", "propose", "suggest"]:
    result = get_meeting_time_suggestions(
        str(option(args, "--eventId")),
        str(option(args, "--searchStart")),
        str(option(args, "--searchEnd")),
        access_token,
        max_candidates=integer_option(
            args, "--maxCandidates", 8, minimum=1
        ),
        minimum_confidence=integer_option(
            args, "--minimumConfidence", 50, minimum=0
        ),
        activity_domain=str(
            option(args, "--activityDomain", required=False) or "work"
        ),
    )
  elif args[:4] == ["teams", "meeting", "propose", "send"]:
    result = propose_new_meeting_time(
        str(option(args, "--eventId")),
        str(option(args, "--start")),
        str(option(args, "--end")),
        str(option(args, "--comment", required=False) or ""),
        access_token,
    )
  elif args[:3] == ["teams", "meeting", "availability"]:
    result = get_meeting_availability(
        str(option(args, "--eventId")),
        str(option(args, "--searchStart")),
        str(option(args, "--searchEnd")),
        access_token,
        max_candidates=integer_option(args, "--maxCandidates", 8, minimum=1),
        minimum_confidence=integer_option(
            args, "--minimumConfidence", 50, minimum=0
        ),
        activity_domain=str(
            option(args, "--activityDomain", required=False) or "work"
        ),
        interval_minutes=integer_option(
            args, "--availabilityInterval", 30, minimum=5
        ),
    )
  elif args[:3] == ["teams", "meeting", "respond"]:
    result = respond_to_meeting(
        str(option(args, "--eventId")),
        str(option(args, "--response")),
        str(option(args, "--comment", required=False) or ""),
        access_token,
    )
  elif args[:3] == ["teams", "meeting", "context"]:
    result = get_meeting_context(
        str(option(args, "--chatId")), access_token
    )
  elif args[:3] == ["teams", "meeting", "transcript"]:
    result = get_meeting_transcript(
        str(option(args, "--chatId")), access_token
    )
  elif args[:4] == ["teams", "chat", "member", "list"]:
    chat_id = str(option(args, "--chatId"))
    result = list_members(chat_id, access_token)
    with TeamsCache() as cache:
      cache.upsert_resources("member", result, parent_id=chat_id)
  elif args[:4] == ["teams", "chat", "message", "list"]:
    chat_id = str(option(args, "--chatId"))
    requested_limit = option(args, "--limit", required=False)
    message_limit = (
        integer_option(args, "--limit", 1, minimum=1)
        if requested_limit is not None
        else None
    )
    result = list_messages(
        chat_id,
        access_token,
        option(args, "--modifiedStartDateTime", required=False),
        message_limit,
    )
    with TeamsCache() as cache:
      cache.upsert_messages("chat", chat_id, result)
  elif args[:3] == ["teams", "chat", "get"]:
    result = find_chat_by_participants(
        str(option(args, "--participants")), access_token
    )
  elif args[:4] == ["teams", "chat", "message", "send"]:
    chat_id = option(args, "--chatId", required=False)
    user_emails = option(args, "--userEmails", required=False)
    if not chat_id and not user_emails:
      raise BackendError("Send requires --chatId or --userEmails")
    if not chat_id:
      chat = find_chat_by_participants(str(user_emails), access_token)
      chat_id = str(chat.get("id") or "")
    result = send_message(
        str(chat_id),
        str(option(args, "--message")),
        access_token,
        option(args, "--replyToId", required=False),
        options(args, "--attachment"),
        options(args, "--mention"),
        option(args, "--contentType", required=False) or "text",
    )
    with TeamsCache() as cache:
      cache.upsert_messages("chat", str(chat_id), [result])
  elif args[:4] == ["teams", "chat", "mark", "read"]:
    result = set_chat_read_state(
        str(option(args, "--chatId")), access_token, unread=False
    )
  elif args[:4] == ["teams", "chat", "mark", "unread"]:
    result = set_chat_read_state(
        str(option(args, "--chatId")), access_token, unread=True
    )
  elif args[:3] == ["teams", "chat", "create"]:
    identifiers = options(args, "--userId")
    user_emails = option(args, "--userEmails", required=False)
    if user_emails:
      identifiers.extend(sorted(parse_participants(user_emails)))
    result = create_chat(
        identifiers,
        access_token,
        topic=option(args, "--topic", required=False),
    )
  elif args[:4] == ["teams", "chat", "topic", "set"]:
    result = set_chat_topic(
        str(option(args, "--chatId")),
        str(option(args, "--topic")),
        access_token,
    )
  elif args[:4] == ["teams", "chat", "member", "add"]:
    result = add_chat_member(
        str(option(args, "--chatId")),
        str(option(args, "--userId")),
        access_token,
    )
  elif args[:4] == ["teams", "chat", "member", "remove"]:
    result = remove_chat_member(
        str(option(args, "--chatId")),
        str(option(args, "--membershipId")),
        access_token,
    )
  elif args == ["teams", "team", "list"]:
    result = list_joined_teams(access_token)
    with TeamsCache() as cache:
      cache.upsert_resources("team", result)
  elif args[:3] == ["teams", "channel", "list"]:
    team_id = str(option(args, "--teamId"))
    result = list_channels(team_id, access_token)
    with TeamsCache() as cache:
      cache.upsert_resources("channel", result, parent_id=team_id)
  elif args[:4] == ["teams", "channel", "message", "list"]:
    team_id = str(option(args, "--teamId"))
    channel_id = str(option(args, "--channelId"))
    result = list_channel_messages(team_id, channel_id, access_token)
    with TeamsCache() as cache:
      cache.upsert_messages(
          "channel",
          channel_id,
          result,
          team_id=team_id,
          channel_id=channel_id,
      )
      for root in result:
        root_id = root.get("id")
        if isinstance(root_id, str):
          cache.upsert_messages(
              "channel",
              channel_id,
              expanded_channel_replies(root, access_token),
              team_id=team_id,
              channel_id=channel_id,
              root_message_id=root_id,
          )
  elif args[:4] == ["teams", "channel", "reply", "list"]:
    team_id = str(option(args, "--teamId"))
    channel_id = str(option(args, "--channelId"))
    message_id = str(option(args, "--messageId"))
    result = list_channel_replies(
        team_id, channel_id, message_id, access_token
    )
    with TeamsCache() as cache:
      cache.upsert_messages(
          "channel",
          channel_id,
          result,
          team_id=team_id,
          channel_id=channel_id,
          root_message_id=message_id,
      )
  elif args[:4] == ["teams", "channel", "message", "send"]:
    result = send_channel_message(
        str(option(args, "--teamId")),
        str(option(args, "--channelId")),
        str(option(args, "--message")),
        access_token,
        reply_to_id=option(args, "--replyToId", required=False),
        attachment_paths=options(args, "--attachment"),
        mention_specs=options(args, "--mention"),
        content_type=option(args, "--contentType", required=False) or "text",
    )
  elif args[:3] in (
      ["teams", "message", "react"],
      ["teams", "message", "unreact"],
      ["teams", "message", "edit"],
      ["teams", "message", "delete"],
      ["teams", "message", "restore"],
  ):
    action = args[2]
    result = mutate_message(
        action,
        str(option(args, "--scope")),
        str(option(args, "--messageId")),
        access_token,
        chat_id=option(args, "--chatId", required=False),
        team_id=option(args, "--teamId", required=False),
        channel_id=option(args, "--channelId", required=False),
        root_message_id=option(args, "--rootMessageId", required=False),
        message=option(args, "--message", required=False),
        reaction=option(args, "--reaction", required=False),
    )
  elif args[:3] == ["teams", "user", "search"]:
    result = search_users(str(option(args, "--query")), access_token)
  elif args[:3] == ["teams", "user", "profile"]:
    result = graph_user(str(option(args, "--userId")), access_token)
  elif args[:3] == ["teams", "user", "presence"]:
    result = get_presence(str(option(args, "--userId")), access_token)
  elif args[:3] == ["teams", "attachment", "download"]:
    result = download_reference_attachment(
        str(option(args, "--url")),
        Path(str(option(args, "--destination"))),
        access_token,
    )
  elif args[:2] == ["teams", "sync"]:
    result = sync_cache(
        access_token,
        scope=option(args, "--scope", required=False) or "chats",
        chat_limit=integer_option(args, "--chatLimit", 25),
        days=integer_option(args, "--days", 7, minimum=1),
    )
  else:
    raise BackendError(f"Unsupported teams4e backend command: {args!r}")

  return result, output


def dispatch(raw_args: list[str]) -> int:
  """Execute the CLI-compatible command in RAW_ARGS."""
  result, output = execute(raw_args)
  if output == "text":
    print(result)
  elif output != "none":
    emit_json(result)
  return 0


def serve() -> int:
  """Serve concurrent command requests as newline-delimited JSON.

  Each input object contains an integer ``id`` and a string-array ``args``.
  Responses contain the same ID plus either ``result`` or a redacted error.
  The protocol is transport-only: command semantics and cache ownership remain
  in :func:`execute`.
  """
  write_lock = threading.Lock()
  workers = ThreadPoolExecutor(max_workers=8)

  def respond(payload: dict[str, Any]) -> None:
    with write_lock:
      emit_json(payload)
      sys.stdout.flush()

  def handle(request: dict[str, Any]) -> None:
    request_id = request.get("id")
    args = request.get("args")
    if not isinstance(request_id, int) or not (
        isinstance(args, list) and all(isinstance(arg, str) for arg in args)
    ):
      respond({"id": request_id, "ok": False, "error": "Invalid request"})
      return
    try:
      result, _output = execute(args)
      respond({"id": request_id, "ok": True, "result": result})
    except BackendError as exception:
      respond({"id": request_id, "ok": False, "error": str(exception)})
    except Exception as exception:  # pragma: no cover - defensive process guard
      respond({
          "id": request_id,
          "ok": False,
          "error": f"Unexpected backend failure: {exception}",
      })

  try:
    for line in sys.stdin:
      if not line.strip():
        continue
      try:
        request = json.loads(line)
      except json.JSONDecodeError:
        respond({"id": None, "ok": False, "error": "Invalid JSON request"})
        continue
      if not isinstance(request, dict):
        respond({"id": None, "ok": False, "error": "Invalid request"})
        continue
      workers.submit(handle, request)
  finally:
    workers.shutdown(wait=True)
  return 0


def main() -> int:
  """Run the backend with user-facing diagnostics."""
  try:
    if sys.argv[1:] == ["serve"]:
      return serve()
    return dispatch(sys.argv[1:])
  except BackendError as exception:
    print(f"ERROR: {exception}", file=sys.stderr)
    return 1
