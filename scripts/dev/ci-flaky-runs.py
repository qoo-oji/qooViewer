#!/usr/bin/env python3
"""再実行で通った CI の回(1 回目は失敗、後の試みで成功)を一覧にする(2026-10-25)。

GitHub の実行の一覧には最後の試みの結果しか出ないので、遅い実行・順序で落ちて手で再実行した回は「成功」に見えて埋もれる。
これは試みが 2 回以上ある回を拾い、失敗した試みの、落ちたジョブ・段・テストを並べる。結果一式(xcresult・整形前のログ)は
失敗した試みの artifact に 30 日残る(.github/workflows/build.yml)。

使い方:
  scripts/dev/ci-flaky-runs.py [--limit 100] [--workflow build.yml]

gh(認証済み)を使う。出力は端末向けの文字だけ。
"""

import argparse
import json
import re
import subprocess
import sys

REPO = "qoo-oji/qooViewer"
ERROR_LINE = re.compile(r"##\[error\](.*)")
TIMESTAMP = re.compile(r"^\S+\t\S+\t\S+Z ")


def gh(*args):
    result = subprocess.run(["gh", *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"gh {' '.join(args[:3])}: {result.stderr.strip()[:300]}")
    return result.stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--workflow", default="build.yml")
    args = parser.parse_args()

    runs = json.loads(gh("api", f"repos/{REPO}/actions/workflows/{args.workflow}/runs?per_page={min(args.limit, 100)}"))
    retried = [run for run in runs["workflow_runs"] if run["run_attempt"] > 1]
    if not retried:
        print("再実行した回はありません。")
        return
    for run in retried:
        print(f"== {run['created_at'][:16]} {run['head_sha'][:7]} {run['display_title'][:60]}")
        print(f"   最後の試み {run['run_attempt']}: {run['conclusion']}  {run['html_url']}")
        for attempt in range(1, run["run_attempt"]):
            jobs = json.loads(gh("api", f"repos/{REPO}/actions/runs/{run['id']}/attempts/{attempt}/jobs"))["jobs"]
            failed = [job for job in jobs if job["conclusion"] == "failure"]
            if not failed:
                conclusion = json.loads(gh("api", f"repos/{REPO}/actions/runs/{run['id']}/attempts/{attempt}"))["conclusion"]
                print(f"   試み {attempt}: {conclusion}(失敗したジョブなし)")
                continue
            for job in failed:
                steps = ", ".join(step["name"] for step in job["steps"] if step["conclusion"] == "failure")
                print(f"   試み {attempt}: {job['name']} ▸ {steps}")
            log = subprocess.run(["gh", "run", "view", str(run["id"]), "-R", REPO, "--attempt", str(attempt), "--log-failed"],
                                 capture_output=True, text=True).stdout
            seen = set()
            for line in log.splitlines():
                match = ERROR_LINE.search(line)
                if not match:
                    continue
                message = match.group(1).strip()
                if message.startswith("Process completed with exit code") or message in seen:
                    continue
                seen.add(message)
                print(f"      {message[:220]}")
                if len(seen) >= 8:
                    print("      …")
                    break


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
