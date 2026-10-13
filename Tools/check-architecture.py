#!/usr/bin/env python3
"""Checks Meshvy's module graph against the tier rules in CONTRIBUTING.md.

SwiftPM already stops a module using anything it has not declared, and it
already rejects cycles. What it does not know is *direction*: nothing in the
manifest stops someone adding `AppShell` to MeshvyCore's dependencies, and by
the time that is noticed the Foundation tier has a view in it.

Run from the repository root:

    python3 Tools/check-architecture.py

Reads `swift package dump-package`, so it sees the graph SwiftPM resolved
rather than a regex over the manifest.
"""
import json
import subprocess
import sys

# Lower may not depend on higher. Equal rank only where ALLOWED_PEERS says so.
TIERS = {
    0: ["MeshvyCore"],
    1: ["MeshvyModels"],
    2: ["ProcessKit", "FileSystemKit"],
    3: ["PersistenceKit", "GitKit", "TerminalKit", "DesignSystem"],
    4: ["AgentKit", "SessionKit", "BrowserKit", "WorkspaceKit", "UpdateKit"],
    5: ["AppState"],
    6: ["AgentsUI", "CanvasUI", "InspectorUI", "WorkspacesUI"],
    7: ["AppShell"],
    8: ["Meshvy"],
}
RANK = {name: rank for rank, names in TIERS.items() for name in names}

# Same-tier edges that are deliberate. Each one needs a reason, and the reason
# is what a reviewer checks when a new entry shows up here.
ALLOWED_PEERS = {
    ("AgentKit", "BrowserKit"):
        "the agent command line advertises the browser's MCP tools",
    ("CanvasUI", "AgentsUI"):
        "node cards show the agent status badges",
}

# Modules that may contain SwiftUI/AppKit views. Anything else importing one of
# these means business logic has reached for the UI.
UI_MODULES = {"DesignSystem", "AgentsUI", "CanvasUI", "InspectorUI",
              "WorkspacesUI", "AppShell", "Meshvy"}


def dependencies(target):
    """Local target names this target depends on (external products ignored)."""
    out = []
    for dep in target.get("dependencies", []):
        for key in ("byName", "target"):
            if key in dep and dep[key]:
                name = dep[key][0]
                if name:
                    out.append(name)
    return out


def main():
    try:
        raw = subprocess.run(["swift", "package", "dump-package"],
                             capture_output=True, text=True, check=True).stdout
    except subprocess.CalledProcessError as error:
        print("could not read the package manifest:", file=sys.stderr)
        print(error.stderr, file=sys.stderr)
        return 2

    package = json.loads(raw)
    problems = []
    seen = set()

    for target in package["targets"]:
        name = target["name"]
        if target["type"] == "test":
            continue
        seen.add(name)
        if name not in RANK:
            problems.append(
                f"{name}: not listed in TIERS. Add it to Tools/check-architecture.py "
                f"with the tier it belongs to, so the rules cover it.")
            continue

        for dep in dependencies(target):
            if dep not in RANK:
                continue  # an external product, or a target the loop above flagged
            if RANK[dep] > RANK[name]:
                problems.append(
                    f"{name} (tier {RANK[name]}) depends on {dep} (tier {RANK[dep]}). "
                    f"A module may only depend on lower tiers.")
            elif RANK[dep] == RANK[name] and (name, dep) not in ALLOWED_PEERS:
                problems.append(
                    f"{name} depends on its own tier ({dep}) and is not in "
                    f"ALLOWED_PEERS. If the edge is deliberate, add it there "
                    f"with the reason.")
            if dep in UI_MODULES and name not in UI_MODULES:
                problems.append(
                    f"{name} depends on {dep}, which holds views. Logic must not "
                    f"reach for the UI — move what is shared down a tier.")

    missing = set(RANK) - seen
    if missing:
        problems.append(
            f"listed in TIERS but not in the package: {', '.join(sorted(missing))}")

    if problems:
        print(f"architecture: {len(problems)} problem(s)\n")
        for problem in problems:
            print(f"  - {problem}")
        return 1

    modules = sum(1 for t in package["targets"] if t["type"] != "test")
    print(f"architecture: {modules} modules, tier rules hold")
    return 0


if __name__ == "__main__":
    sys.exit(main())
