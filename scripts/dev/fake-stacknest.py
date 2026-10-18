#!/usr/bin/env python3
"""StackNest の本の API の作り物(実機で StackNest の本を確かめるときだけ使う。docs/12「StackNest の本の実機の確かめ方」)。

使い方:
  fake-stacknest.py serve --port 51990 --pages 12 --token <鍵> [--log <ファイル>] [--progress-status 204] [--hang]
                    [--page-delay-ms 0] [--image <画像ファイル>]
  fake-stacknest.py reference <参照ファイルの置き場所> --port 51990 --pages 12 --token <鍵> [--start 0] [--title …]
                    [--direction rtl] [--expired]

- serve: 127.0.0.1 だけで待ち受け、manifest・pages/<n>(番号入りの PNG)・cover・progress に答える。鍵が違えば 401。
  受けた要求を 1 行ずつ --log に書く(先頭に時刻。POST は本文も。ページは返し終えた時刻と所要の DONE の行も)。
  --progress-status で読書位置の POST の答えを変えられる(401 で書き戻しの失敗)。
  --hang は接続を受けるだけで何も答えない(応答しない StackNest)。--page-delay-ms はページ 1 枚を返すまで待つ(遅い StackNest ―― リモートの
  ライブラリの中継など。速さの測定に使う)。--image で、番号入りの PNG の代わりにそのファイルの中身をどのページにも返す(実際の大きさの
  ページで測る)。
- reference: 参照ファイル(.stacknestbook)を書く。StackNest が渡し直したのと同じく、同じパスへ何度でも書き直せる。
  qooViewer は Debug でもサンドボックスの中なので、参照ファイルは Debug のコンテナの tmp/ の下に置く
  (~/Library/Containers/com.qooProject.qooViewer.debug/Data/tmp/…)。
"""
import argparse
import datetime
import time
import http.server
import json
import socket
import struct
import sys
import zlib


def png(number):
    """番号ごとに色の違う 60×90 の PNG(ページの見分け用)。"""
    width, height = 60, 90
    row = b"\x00" + bytes([min(number * 20, 255), 80, 160]) * width
    raw = row * height

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


def serve(args):
    log = open(args.log, "a", buffering=1) if args.log else sys.stdout
    image_bytes = open(args.image, "rb").read() if args.image else None
    if args.hang:
        listener = socket.socket()
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", args.port))
        listener.listen(512)
        held = []
        while True:
            connection, _ = listener.accept()
            held.append(connection)
            log.write("accepted (hang)\n")

    class Handler(http.server.BaseHTTPRequestHandler):
        def _authorized(self):
            return self.headers.get("Authorization") == "Bearer " + args.token

        def _send(self, code, body=b"", content_type="application/json"):
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

        def do_GET(self):
            started = time.time()
            log.write(f"{started:.3f} GET {self.path} auth={'ok' if self._authorized() else 'bad'} "
                      f"viewer={self.headers.get('X-StackNest-Viewer')}\n")
            if not self._authorized():
                return self._send(401)
            parts = self.path.split("?")[0].split("/")
            if parts[-1] == "manifest":
                manifest = {"pageCount": args.pages, "direction": args.direction, "format": "archive", "etag": "e1"}
                return self._send(200, json.dumps(manifest).encode())
            if parts[-1] == "cover":
                return self._send(200, png(1), "image/png")
            if len(parts) >= 2 and parts[-2] == "pages" and parts[-1].isdigit() and int(parts[-1]) < args.pages:
                if args.page_delay_ms:
                    time.sleep(args.page_delay_ms / 1000)
                try:
                    if image_bytes is not None:
                        return self._send(200, image_bytes, "image/jpeg")
                    return self._send(200, png(int(parts[-1]) + 1), "image/png")
                finally:
                    log.write(f"{time.time():.3f} DONE {self.path} ms={int((time.time() - started) * 1000)}\n")
            return self._send(404)

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(min(length, 1 << 16))
            log.write(f"{time.time():.3f} POST {self.path} auth={'ok' if self._authorized() else 'bad'} "
                      f"body={body.decode(errors='replace')}\n")
            if not self._authorized():
                return self._send(401)
            return self._send(args.progress_status)

    http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


def reference(args):
    expires = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=-1 if args.expired else 1)
    document = {
        "format": "stacknest-book-reference",
        "version": 1,
        "title": args.title,
        "book": f"http://127.0.0.1:{args.port}/api/v1/relay/{args.relay}",
        "token": args.token,
        "expiresAt": expires.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "pageCount": args.pages,
        "direction": args.direction,
        "startPage": args.start,
    }
    with open(args.path, "w") as file:
        json.dump(document, file)
    print(args.path)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("serve", "reference"):
        command = commands.add_parser(name)
        if name == "reference":
            command.add_argument("path")
            command.add_argument("--start", type=int, default=0)
            command.add_argument("--title", default="Fake StackNest Book")
            command.add_argument("--relay", default="fake")
            command.add_argument("--expired", action="store_true")
        else:
            command.add_argument("--log")
            command.add_argument("--progress-status", type=int, default=204)
            command.add_argument("--hang", action="store_true")
            command.add_argument("--page-delay-ms", type=int, default=0)
            command.add_argument("--image")
        command.add_argument("--port", type=int, required=True)
        command.add_argument("--pages", type=int, default=12)
        command.add_argument("--token", required=True)
        command.add_argument("--direction", default="rtl", choices=["rtl", "ltr"])
    args = parser.parse_args()
    serve(args) if args.command == "serve" else reference(args)


if __name__ == "__main__":
    main()
