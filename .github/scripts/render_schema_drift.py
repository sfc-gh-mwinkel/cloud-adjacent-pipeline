import json
import os
from pathlib import Path


MARKER = "DBT_CI_SCHEMA_DRIFT "
LOG_PATH = Path(os.environ.get("DBT_LOG_PATH", "logs")) / "dbt.log"
REPORT_PATH = Path("schema-drift-report.md")


def escape_workflow_command(value):
    return str(value).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def markdown_cell(value):
    return str(value).replace("|", "\\|").replace("\n", " ")


def display_list(values):
    if not values:
        return "None"
    return ", ".join(str(value) for value in values)


def read_findings():
    if not LOG_PATH.exists():
        return []

    findings = []
    seen = set()
    for line in LOG_PATH.read_text(encoding="utf-8", errors="replace").splitlines():
        marker_position = line.find(MARKER)
        if marker_position == -1:
            continue
        payload = line[marker_position + len(MARKER) :]
        try:
            finding = json.loads(payload)
        except json.JSONDecodeError:
            continue
        identity = finding.get("relation") or finding.get("model")
        if identity not in seen:
            findings.append(finding)
            seen.add(identity)
    return findings


def render(findings, build_outcome):
    lines = ["<!-- dbt-ci-schema-drift -->", "## dbt CI schema drift"]
    if not findings:
        if build_outcome == "success":
            status = "No incremental model schema drift was detected."
        else:
            status = "Schema drift could not be fully evaluated because the dbt build did not succeed."
        lines.extend(["", status])
        return "\n".join(lines) + "\n"

    lines.extend(
        [
            "",
            "dbt synchronized the cloned CI relations. Review whether production needs a full refresh because schema synchronization does not backfill historical rows.",
            "",
            "| Model | Added columns | Removed columns | Changed types |",
            "|---|---|---|---|",
        ]
    )
    for finding in findings:
        lines.append(
            "| {model} | {added} | {removed} | {changed} |".format(
                model=markdown_cell(finding.get("model", finding.get("relation", "Unknown"))),
                added=markdown_cell(display_list(finding.get("added_columns", []))),
                removed=markdown_cell(display_list(finding.get("removed_columns", []))),
                changed=markdown_cell(display_list(finding.get("changed_types", []))),
            )
        )
    return "\n".join(lines) + "\n"


findings = read_findings()
report = render(findings, os.environ.get("DBT_BUILD_OUTCOME", "unknown"))
REPORT_PATH.write_text(report, encoding="utf-8")

summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
if summary_path:
    with open(summary_path, "a", encoding="utf-8") as summary:
        summary.write(report)

for finding in findings:
    message = "Schema drift in {model}: added [{added}], removed [{removed}], changed types [{changed}]. Production may require a full refresh.".format(
        model=finding.get("model", finding.get("relation", "unknown model")),
        added=display_list(finding.get("added_columns", [])),
        removed=display_list(finding.get("removed_columns", [])),
        changed=display_list(finding.get("changed_types", [])),
    )
    print(f"::warning::{escape_workflow_command(message)}")

github_output = os.environ.get("GITHUB_OUTPUT")
if github_output:
    with open(github_output, "a", encoding="utf-8") as output:
        output.write(f"has_drift={'true' if findings else 'false'}\n")