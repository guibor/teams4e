"""Connection reuse, TLS policy, proxy fallback and read-only dispatch tests."""

import http.client
import http.server
import io
import ssl
import sys
import threading
import unittest
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin"))
import teams4e_graph as backend
import teams4e_http as transport


class FakeResponse(io.BytesIO):
  def __init__(self, status=200):
    super().__init__(b'{"value":[]}')
    self.status = status
    self.reason = "fixture"
    self.headers = {"Retry-After": "10"}


def connection():
  value = mock.Mock()
  value.sock = None
  value.getresponse.side_effect = FakeResponse
  return value


class HTTPTransportTests(unittest.TestCase):
  def setUp(self):
    self.pool = transport.GraphReadTransport("graph.microsoft.com")
    patcher = mock.patch.object(transport.urllib.request, "getproxies", return_value={})
    patcher.start()
    self.addCleanup(patcher.stop)
    self.addCleanup(self.pool.close)

  def request(self, token="fixture-one"):
    return urllib.request.Request("https://graph.microsoft.com/v1.0/chats/fixture/messages?$top=50",
                                  headers={"Authorization": "Bearer " + token})

  def test_reuses_verified_socket_but_not_old_authorization(self):
    conn = connection()
    with mock.patch.object(transport.http.client, "HTTPSConnection", return_value=conn) as create:
      for token in ("fixture-one", "fixture-two"):
        with self.pool.open(self.request(token)) as response:
          self.assertEqual(b'{"value":[]}', response.read())
    create.assert_called_once()
    context = create.call_args.kwargs["context"]
    self.assertEqual(ssl.CERT_REQUIRED, context.verify_mode)
    self.assertTrue(context.check_hostname)
    self.assertEqual(["Bearer fixture-one", "Bearer fixture-two"],
                     [call.kwargs["headers"]["Authorization"] for call in conn.request.call_args_list])
    self.assertEqual("/v1.0/chats/fixture/messages?$top=50", conn.request.call_args.args[1])

  def test_worker_threads_never_share_a_connection(self):
    barrier = threading.Barrier(2)
    created = []

    def make(*args, **kwargs):
      conn = connection()
      created.append(conn)
      return conn

    def read(_):
      self.pool.open(self.request()).close()
      barrier.wait(timeout=3)
      self.pool.open(self.request()).close()
      self.pool.close()

    with mock.patch.object(transport.http.client, "HTTPSConnection", side_effect=make):
      with ThreadPoolExecutor(max_workers=2) as workers:
        list(workers.map(read, range(2)))
    self.assertEqual(2, len(created))
    self.assertTrue(all(conn.request.call_count == 2 for conn in created))

  def test_stale_connection_is_discarded_not_retried_inside_transport(self):
    broken, fresh = connection(), connection()
    broken.getresponse.side_effect = http.client.RemoteDisconnected("fixture close")
    with mock.patch.object(transport.http.client, "HTTPSConnection", side_effect=[broken, fresh]) as create:
      with self.assertRaises(urllib.error.URLError):
        self.pool.open(self.request())
      self.assertEqual(1, create.call_count)
      broken.close.assert_called_once()
      self.pool.open(self.request()).close()
      self.assertEqual(2, create.call_count)

  def test_idle_connection_is_replaced(self):
    with mock.patch.object(transport.http.client, "HTTPSConnection", side_effect=lambda *a, **k: connection()) as create:
      self.pool.open(self.request()).close()
      old = self.pool.local.connection
      self.pool.local.last_used -= 31
      self.pool.open(self.request()).close()
      self.assertEqual(2, create.call_count)
      old.close.assert_called_once()

  def test_proxy_configuration_uses_existing_urllib_transport(self):
    with (mock.patch.object(transport.urllib.request, "getproxies", return_value={"https": "http://proxy.example:8080"}),
          mock.patch.object(transport.urllib.request, "urlopen", return_value=FakeResponse()) as open_url,
          mock.patch.object(transport.http.client, "HTTPSConnection") as create):
      request = self.request()
      self.pool.open(request, timeout=12).close()
      open_url.assert_called_once_with(request, timeout=12)
      create.assert_not_called()

  def test_no_proxy_alone_does_not_disable_connection_reuse(self):
    with (mock.patch.object(transport.urllib.request, "getproxies", return_value={"no": "localhost"}),
          mock.patch.object(transport.http.client, "HTTPSConnection", return_value=connection()) as create):
      self.pool.open(self.request()).close()
      self.pool.open(self.request()).close()
      create.assert_called_once()

  def test_rejects_external_hosts_ports_and_writes(self):
    for request in (urllib.request.Request("https://example.test/token"),
                    urllib.request.Request("https://graph.microsoft.com:444/v1.0/me"),
                    urllib.request.Request("http://graph.microsoft.com/v1.0/me"),
                    urllib.request.Request("https://user@graph.microsoft.com/v1.0/me"),
                    urllib.request.Request("https://graph.microsoft.com/v1.0/me", data=b"send")):
      with self.subTest(url=request.full_url), self.assertRaises(ValueError):
        self.pool.open(request)

  def test_http_errors_keep_headers_and_never_follow_redirects(self):
    for status in (302, 429, 503):
      self.pool.close()
      conn = connection()
      conn.getresponse.side_effect = lambda: FakeResponse(status)
      with mock.patch.object(transport.http.client, "HTTPSConnection", return_value=conn):
        with self.assertRaises(urllib.error.HTTPError) as error:
          self.pool.open(self.request())
        self.assertEqual(status, error.exception.code)
        self.assertEqual("10", error.exception.headers["Retry-After"])
        self.assertEqual(b'{"value":[]}', error.exception.read())
        self.assertEqual(1, conn.request.call_count)

  def test_backend_enables_pool_only_for_persistent_gets(self):
    for persistent, method in ((True, "GET"), (False, "GET"), (True, "POST")):
      context = backend.KEEP_ALIVE.set(persistent)
      try:
        with (mock.patch.object(backend.GRAPH_REQUEST_BUDGET, "acquire"),
              mock.patch.object(backend.GRAPH_READ_TRANSPORT, "open", return_value=FakeResponse()) as pooled,
              mock.patch.object(backend.urllib.request, "urlopen", return_value=FakeResponse()) as ordinary):
          backend.graph_json("/me", "fixture-token", method=method)
          self.assertEqual(int(persistent and method == "GET"), pooled.call_count)
          self.assertEqual(int(not (persistent and method == "GET")), ordinary.call_count)
      finally:
        backend.KEEP_ALIVE.reset(context)

  def test_real_http_framing_reuses_socket_and_recovers_server_close(self):
    sockets = []

    class Handler(http.server.BaseHTTPRequestHandler):
      protocol_version = "HTTP/1.1"

      def setup(self):
        super().setup()
        sockets.append(self.connection)

      def do_GET(self):
        body = b'{"value":[]}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        if self.path == "/close":
          self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

      def log_message(self, *args):
        pass

    try:
      server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    except PermissionError:
      self.skipTest("Sandbox disallows loopback sockets")
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
      def local_connection(*args, **kwargs):
        return http.client.HTTPConnection(*server.server_address, timeout=2)

      with mock.patch.object(transport.http.client, "HTTPSConnection", side_effect=local_connection):
        for path in ("/first", "/second", "/close", "/after-close"):
          request = urllib.request.Request("https://graph.microsoft.com" + path)
          with self.pool.open(request) as response:
            self.assertEqual(b'{"value":[]}', response.read())
        self.assertEqual(2, len(sockets))
    finally:
      self.pool.close()
      server.shutdown()
      server.server_close()
      thread.join(3)
