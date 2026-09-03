import json
import os
import subprocess
from pathlib import Path


MARKER = "<!-- dbt-ci-schema-drift -->"
REPORT_PATH = Path("schema-drift-report.md")
repository = os.environ["GITHUB_REPOSITORY"]
pull_request = os.environ["PR_NUMBER"]


def run_gh(arguments, input_text=None, check=True):
    return subprocess.run(
        ["gh", *arguments],
        input=input_text,
        text=True,
        capture_output=True,
        check=check,
    )


if not REPORT_PATH.exists():
    raise SystemExit(0)

report = REPORT_PATH.read_text(encoding="utf-8")
comments_response = run_gh(
    [
        "api",
        f"repos/{repository}/issues/{pull_request}/comments",
        "--paginate",
        "--slurp",
    ]
)
comment_pages = json.loads(comments_response.stdout)
comments = [comment for page in comment_pages for comment in page]
existing = next(
    (comment for comment in comments if MARKER in (comment.get("body") or "")),
    None,
)

payload = json.dumps({"body": report})
if existing:
    endpoint = f"repos/{repository}/issues/comments/{existing['id']}"
    method = "PATCH"
else:
    endpoint = f"repos/{repository}/issues/{pull_request}/comments"
    method = "POST"

result = run_gh(
    ["api", "--method", method, endpoint, "--input", "-"],
    input_text=payload,
    check=False,
)
if result.returncode != 0:
    print(f"Unable to update schema drift PR comment: {result.stderr.strip()}")