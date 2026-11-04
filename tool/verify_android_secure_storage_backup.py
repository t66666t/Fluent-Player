"""Check selective Android secure-storage backup exclusions without device IO.

API 24-30 use fullBackupContent; API 31+ use separate cloud/device rules.
An optional APK check inspects the actual compiled manifest and resource entries,
not just the source XML. This does not execute a backup or restore transport.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
ANDROID = "{http://schemas.android.com/apk/res/android}"
PREFS = frozenset({"FlutterSecureStorage.xml", "FlutterSecureKeyStorage.xml"})
RESOURCES = {
    "fullBackupContent": "backup_rules",
    "dataExtractionRules": "data_extraction_rules",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def check_exclusions(node: ET.Element, label: str) -> None:
    require(not node.attrib, f"{label}: backup-wide attributes change the existing policy")
    actual = []
    for child in node:
        require(child.tag == "exclude", f"{label}: only selective exclusions are allowed")
        require(not list(child), f"{label}: unexpected nested rule")
        require(set(child.attrib) == {"domain", "path"}, f"{label}: unexpected rule attributes")
        actual.append((child.get("domain"), child.get("path")))
    expected = {("sharedpref", name) for name in PREFS}
    require(len(actual) == len(expected) and set(actual) == expected,
            f"{label}: expected only these secure prefs exclusions: {sorted(PREFS)}; got {actual}")


def check_rules(root: ET.Element, resource: str) -> None:
    if resource == "backup_rules":
        require(root.tag == "full-backup-content", "legacy rules must use full-backup-content")
        check_exclusions(root, "API 24-30 full backup")
    else:
        require(root.tag == "data-extraction-rules" and not root.attrib,
                "modern rules must use data-extraction-rules without global attributes")
        children = list(root)
        require(len(children) == 2 and {child.tag for child in children}
                == {"cloud-backup", "device-transfer"},
                "API 31+ requires both cloud-backup and device-transfer rules")
        for child in children:
            check_exclusions(child, f"API 31+ {child.tag}")


def check_application(application: ET.Element, refs: dict[str, str]) -> None:
    require(application.get(ANDROID + "allowBackup", "true") in {"true", "0xffffffff"},
            "do not disable the application's existing backup policy")
    require(application.get(ANDROID + "backupAgent") is None,
            "custom backupAgent needs an explicit compatibility review")
    for attribute, expected in refs.items():
        require(application.get(ANDROID + attribute) == expected,
                f"application android:{attribute} must reference {expected}; "
                f"got {application.get(ANDROID + attribute)!r}")


def check_source(root: Path) -> dict:
    main = root / "android/app/src/main"
    manifest = ET.parse(main / "AndroidManifest.xml").getroot()
    applications = manifest.findall("application")
    require(len(applications) == 1, "expected exactly one application")
    check_application(applications[0], {key: "@xml/" + value for key, value in RESOURCES.items()})
    files = [main / "AndroidManifest.xml"]
    for resource in RESOURCES.values():
        variants = sorted((main / "res").glob(f"xml*/{resource}.xml"))
        require(main / "res/xml" / (resource + ".xml") in variants,
                f"missing default {resource}.xml (required on API 24)")
        for path in variants:
            check_rules(ET.parse(path).getroot(), resource)
        files.extend(variants)
    return {"sourceSha256": {str(path.relative_to(root)).replace("\\", "/"):
                             hashlib.sha256(path.read_bytes()).hexdigest() for path in files}}


def parse_xmltree(output: str) -> ET.Element:
    """Decode the aapt2 xmltree subset used by manifests and backup rules."""
    stack: list[tuple[int, ET.Element]] = []
    root = None
    for line in output.splitlines():
        element = re.match(r"^(\s*)E: ([\w.-]+)(?:\s|$)", line)
        if element:
            indent = len(element[1])
            while stack and stack[-1][0] >= indent:
                stack.pop()
            node = ET.Element(element[2])
            if stack:
                stack[-1][1].append(node)
            else:
                require(root is None, "aapt2 returned more than one root element")
                root = node
            stack.append((indent, node))
            continue
        attribute = re.match(r"^\s*A: (?:(http://schemas.android.com/apk/res/android|android):)?"
                             r"([\w.-]+)(?:\(0x[0-9a-fA-F]+\))?=(.*)$", line)
        if attribute and stack:
            name = (ANDROID if attribute[1] else "") + attribute[2]
            value = attribute[3]
            if value.startswith('"'):
                # aapt2's display format is not JSON: manifest pathPattern
                # strings can contain literal backslash-dot glob escapes.
                quoted = re.match(r'^"((?:\\.|[^"\\])*)"', value)
                require(quoted is not None, "invalid quoted aapt2 attribute")
                value = quoted[1].replace(r'\"', '"')
            stack[-1][1].set(name, value)
    require(root is not None, "aapt2 returned no XML elements")
    return root


def parse_resources(output: str) -> dict[str, tuple[str, list[str]]]:
    resources = {}
    current = None
    for line in output.splitlines():
        match = re.match(r"\s*resource (0x[0-9a-fA-F]+) xml/([\w]+)(?:\s|$)", line)
        if match:
            current = match[2]
            resources[current] = (match[1].lower(), [])
        elif re.match(r"\s*resource ", line):
            current = None
        file = re.search(r"\(file\) (\S+)", line)
        if file and current:
            resources[current][1].append(file[1])
    return resources


def check_apk(apk: Path, aapt2: Path) -> dict:
    def dump(*arguments: str) -> str:
        result = subprocess.run([str(aapt2), "dump", *arguments], capture_output=True,
                                text=True, encoding="utf-8", errors="strict", check=True)
        return result.stdout

    manifest = parse_xmltree(dump("xmltree", str(apk), "--file", "AndroidManifest.xml"))
    applications = manifest.findall("application")
    require(len(applications) == 1, "APK must contain exactly one application")
    table = parse_resources(dump("resources", str(apk)))
    refs = {}
    checked_files = []
    for attribute, resource in RESOURCES.items():
        require(resource in table, f"APK missing xml/{resource}")
        resource_id, files = table[resource]
        require(bool(files), f"APK xml/{resource} has no file configurations")
        refs[attribute] = "@" + resource_id
        for file in sorted(set(files)):
            check_rules(parse_xmltree(dump("xmltree", str(apk), "--file", file)), resource)
            checked_files.append(file)
    check_application(applications[0], refs)
    return {"apk": str(apk.resolve()), "apkSha256": hashlib.sha256(apk.read_bytes()).hexdigest(),
            "compiledReferences": refs, "compiledRuleFiles": checked_files}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--apk", type=Path)
    parser.add_argument("--aapt2", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if bool(args.apk) != bool(args.aapt2):
        parser.error("--apk and --aapt2 must be supplied together")
    try:
        result = check_source(args.root.resolve())
        if args.apk:
            result.update(check_apk(args.apk, args.aapt2))
        result.update(status="pass", excludedPreferences=sorted(PREFS),
                      api24To30="fullBackupContent", api31Plus="cloud-backup and device-transfer",
                      otherDataPolicy="unchanged default inclusion; no include/global disable rules",
                      deviceOperations=0, backupRestoreTransportExecuted=False)
    except (ValueError, ET.ParseError, OSError, subprocess.CalledProcessError) as error:
        result = {"status": "fail", "error": str(error), "deviceOperations": 0}
    output = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
    if args.output:
        args.output.write_text(output, encoding="utf-8")
    print(output, end="")
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
