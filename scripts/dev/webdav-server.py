#!/usr/bin/env python3
"""Minimal read-only WebDAV server for reproducing an unresponsive network volume.

usage: webdav-server.py <root folder> <port>
Mount it with `/sbin/mount_webdav -S http://127.0.0.1:<port>/ <mount point>`, then `kill -STOP` this
process: stat on not-yet-fetched paths under the mount blocks for 40-90 s (measured 2026-09-13).
`kill -CONT` releases it. See docs/12-verification-and-debugging.md.
"""
import http.server, os, sys, email.utils, html
ROOT = sys.argv[1]; PORT = int(sys.argv[2])
def entry(href, path):
    st = os.stat(path); isdir = os.path.isdir(path)
    rt = "<D:resourcetype><D:collection/></D:resourcetype>" if isdir else "<D:resourcetype/>"
    ln = "" if isdir else f"<D:getcontentlength>{st.st_size}</D:getcontentlength>"
    lm = email.utils.formatdate(st.st_mtime, usegmt=True)
    return (f"<D:response><D:href>{html.escape(href)}</D:href><D:propstat><D:prop>{rt}{ln}"
            f"<D:getlastmodified>{lm}</D:getlastmodified><D:creationdate>2026-01-01T00:00:00Z</D:creationdate>"
            f"</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>")
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def local(self):
        from urllib.parse import unquote
        return os.path.join(ROOT, unquote(self.path.split("?")[0]).lstrip("/"))
    def send(self, code, body=b"", ctype="text/xml; charset=utf-8", extra=None):
        self.send_response(code)
        for k, v in (extra or {}).items(): self.send_header(k, v)
        self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_OPTIONS(self):
        self.send(200, extra={"DAV": "1,2", "Allow": "OPTIONS, GET, HEAD, PROPFIND", "MS-Author-Via": "DAV"})
    def do_PROPFIND(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        if n: self.rfile.read(n)
        p = self.local()
        if not os.path.exists(p): return self.send(404)
        href = self.path if self.path.endswith("/") or not os.path.isdir(p) else self.path + "/"
        parts = [entry(href, p)]
        if os.path.isdir(p) and self.headers.get("Depth", "1") != "0":
            for name in sorted(os.listdir(p)):
                c = os.path.join(p, name)
                parts.append(entry(href + name + ("/" if os.path.isdir(c) else ""), c))
        body = ('<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">' + "".join(parts) + "</D:multistatus>").encode()
        self.send(207, body)
    def do_HEAD(self):
        p = self.local()
        if not os.path.isfile(p): return self.send(404) if not os.path.isdir(p) else self.send(200)
        self.send_response(200); self.send_header("Content-Length", str(os.path.getsize(p))); self.end_headers()
    def do_GET(self):
        p = self.local()
        if not os.path.isfile(p): return self.send(404)
        with open(p, "rb") as f: self.send(200, f.read(), "application/octet-stream")
    def do_LOCK(self): self.send(405)
http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
