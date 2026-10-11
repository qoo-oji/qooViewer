#!/usr/bin/env python3
"""Debug ビルドの qooViewer を、画面を操作せずに動かして状態を読む(App/DebugControlPort.swift の相手)。

使い方:
  qoo-debug-control.py wait-ready [--timeout 60]
  qoo-debug-control.py state
  qoo-debug-control.py menu
  qoo-debug-control.py open /path/to/book [--via finder]
  qoo-debug-control.py send <command> ['{"json": "arguments"}']

置き場所は --dir、環境変数 QOO_DEBUG_CONTROL_DIR、Debug のコンテナの tmp/(サンドボックスの中)、
$(getconf DARWIN_USER_TEMP_DIR)(署名していない CI のビルド)の順に探す。結果は JSON で標準出力へ。
失敗(アプリが断った・時間切れ)は終了コード 1。
"""

import argparse
import json
import os
import subprocess
import sys
import time
import uuid

BUNDLE_ID = "com.qooProject.qooViewer.debug"
FOLDER = "qooViewer-debug-control"


def candidate_dirs(explicit):
    if explicit:
        return [explicit]
    if os.environ.get("QOO_DEBUG_CONTROL_DIR"):
        return [os.environ["QOO_DEBUG_CONTROL_DIR"]]
    dirs = [os.path.expanduser(f"~/Library/Containers/{BUNDLE_ID}/Data/tmp/{FOLDER}")]
    try:
        temp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True, check=True).stdout.strip()
        dirs.append(os.path.join(temp, FOLDER))
    except (OSError, subprocess.CalledProcessError):
        pass
    return dirs


def is_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def ready_dir(explicit):
    """生きているアプリの ready.json がある置き場所。無ければ None。"""
    for directory in candidate_dirs(explicit):
        try:
            with open(os.path.join(directory, "ready.json")) as handle:
                ready = json.load(handle)
        except (OSError, ValueError):
            continue
        if is_alive(int(ready.get("pid", 0))):
            return directory, ready
    return None


def wait_ready(explicit, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        found = ready_dir(explicit)
        if found:
            return found
        time.sleep(0.2)
    return None


def send(explicit, command, arguments, timeout):
    found = ready_dir(explicit)
    if not found:
        raise SystemExit("qooViewer (Debug) is not running, or its control port is not ready")
    directory, _ = found
    request_id = f"{int(time.time() * 1000)}-{uuid.uuid4().hex[:8]}"
    inbox = os.path.join(directory, "inbox")
    temporary = os.path.join(inbox, f".{request_id}.partial")
    with open(temporary, "w") as handle:
        json.dump({"id": request_id, "command": command, "arguments": arguments}, handle)
    # 書きかけを読ませない(アプリは .json だけを拾う)。
    os.rename(temporary, os.path.join(inbox, f"{request_id}.json"))
    response_path = os.path.join(directory, "outbox", f"{request_id}.json")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(response_path):
            try:
                with open(response_path) as handle:
                    response = json.load(handle)
            except ValueError:
                time.sleep(0.05)
                continue
            os.remove(response_path)
            return response
        time.sleep(0.05)
    raise SystemExit(f"no response to {command} within {timeout} s")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dir")
    parser.add_argument("--timeout", type=float, default=30)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("wait-ready")
    sub.add_parser("state")
    sub.add_parser("menu")
    opener = sub.add_parser("open")
    opener.add_argument("path")
    opener.add_argument("--via", choices=["window", "finder"], default="window")
    sender = sub.add_parser("send")
    sender.add_argument("command")
    sender.add_argument("arguments", nargs="?", default="{}")
    args = parser.parse_args()

    if args.action == "wait-ready":
        found = wait_ready(args.dir, args.timeout)
        if not found:
            print(json.dumps({"ok": False, "error": "not ready"}))
            return 1
        directory, ready = found
        print(json.dumps({"ok": True, "directory": directory, "ready": ready}))
        return 0
    if args.action == "open":
        command, arguments = "open", {"path": os.path.abspath(args.path), "via": args.via}
    elif args.action == "send":
        command, arguments = args.command, json.loads(args.arguments)
    else:
        command, arguments = args.action, {}
    response = send(args.dir, command, arguments, args.timeout)
    print(json.dumps(response, ensure_ascii=False, indent=2))
    return 0 if response.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
