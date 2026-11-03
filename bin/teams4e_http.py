# SPDX-License-Identifier: GPL-3.0-or-later
"""Worker-local HTTPS keep-alive for direct, read-only Graph JSON requests."""

from __future__ import annotations

import http.client
import io
import ssl
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


class GraphReadTransport:
  """Reuse one verified connection per worker, without sharing bearer headers.

  HTTP framing and TLS verification belong to Python's standard library.
  Configured proxies retain urllib's existing environment/macOS proxy handling.
  Retries stay in the backend's rate-limited loop. Direct connections never
  follow redirects. This transport cannot send a mutation.
  """

  def __init__(self, host: str):
    self.host = host
    self.local = threading.local()
    self.lock = threading.Lock()
    self.context = None
    self.proxied = None

  def close(self) -> None:
    connection = getattr(self.local, "connection", None)
    self.local.connection = None
    if connection is not None:
      connection.close()

  def open(self, request: urllib.request.Request, timeout: float = 60):
    url = urllib.parse.urlsplit(request.full_url)
    if (request.get_method() != "GET" or url.scheme != "https"
        or url.hostname != self.host or url.port not in (None, 443)
        or url.username is not None or url.password is not None):
      raise ValueError("Keep-alive transport accepts only direct Graph GET requests")
    with self.lock:
      if self.proxied is None:
        self.proxied = any(value for key, value in urllib.request.getproxies().items()
                           if key in {"http", "https", "all"})
      if not self.proxied and self.context is None:
        self.context = ssl.create_default_context()
        self.context.set_alpn_protocols(["http/1.1"])
    if self.proxied:
      return urllib.request.urlopen(request, timeout=timeout)

    connection = getattr(self.local, "connection", None)
    if connection is not None and time.monotonic() - self.local.last_used > 30:
      self.close()
      connection = None
    if connection is None:
      connection = http.client.HTTPSConnection(self.host, timeout=timeout,
                                              context=self.context)
      self.local.connection = connection
    try:
      connection.timeout = timeout
      if connection.sock is not None:
        connection.sock.settimeout(timeout)
      path = urllib.parse.urlunsplit(("", "", url.path or "/", url.query, ""))
      connection.request("GET", path, headers=dict(request.header_items()))
      response = connection.getresponse()
      body = response.read()  # Consume the response before reusing its socket.
      self.local.last_used = time.monotonic()
    except (OSError, http.client.HTTPException) as error:
      self.close()
      raise urllib.error.URLError(str(error)) from error
    if response.status >= 300:
      raise urllib.error.HTTPError(request.full_url, response.status,
                                   response.reason, response.headers, io.BytesIO(body))
    return io.BytesIO(body)
