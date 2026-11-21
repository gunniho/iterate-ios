#!/usr/bin/env python3
"""Configure the Xcode targets and optionally install the mobile facet in an Iterate mind."""

import argparse
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from urllib.error import URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


REPO = Path(__file__).resolve().parents[1]
MODULES = ("backend.ts", "integration.js", "integration.d.ts", "mobile.js",
           "push.js", "memory.js", "agent-voice.js")
VOICE_VERSION = "0.1.0-main.20261119T232115Z-355995d"
VOICE_SHIM = 'export { default, VoiceAgentDurableObject } from "@iterate-com/voice";\n'
LABEL = re.compile(r"[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?")


def hostname(value):
    value = value.strip()
    if "://" in value:
        url = urlsplit(value)
        if url.scheme != "https" or url.path not in ("", "/") or url.query or url.fragment:
            raise ValueError("Use a hostname or its HTTPS origin, without a path or query.")
        value = url.netloc
    value = value.rstrip(".").encode("idna").decode("ascii").lower()
    if "." not in value or len(value) > 253 or not all(LABEL.fullmatch(label) for label in value.split(".")):
        raise ValueError("Invalid hostname. Use the DNS name of your Iterate deployment.")
    return value


def checked_mind_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", value) or value == "0" * 64:
        raise ValueError("The mind ID must be the 64-digit hexadecimal identity of your mind.")
    return value.lower()


class ExactOrigin(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("Identity discovery redirected. Supply your mind's canonical control hostname.")


def discover_mind(control_host):
    address = f"https://{control_host}/.well-known/iterate"
    request = Request(address, headers={"Accept": "application/json", "User-Agent": "Iterate-iOS-Setup/1.0"})
    limit = 1024 * 1024
    try:
        with build_opener(ExactOrigin()).open(request, timeout=12) as response:
            payload = response.read(limit + 1)
    except URLError as error:
        raise ValueError(f"Could not read {address} ({error.reason}). Check --control-host or supply the verified --mind-id.") from error
    if len(payload) > limit:
        raise ValueError("The identity document exceeds 1 MiB. Supply the verified ID with --mind-id.")
    document = json.loads(payload)
    return checked_mind_id(document.get("mind") if isinstance(document, dict) else None)


def write_if_changed(path, content, private=False):
    if path.is_file() and path.read_text() == content:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as output:
        temporary = Path(output.name)
        try:
            output.write(content)
            output.flush()
            os.chmod(temporary, 0o600 if private else 0o644)
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


def backend_files(root, deployment, replace):
    package_file = root / "package.json"
    if not package_file.is_file():
        raise ValueError("--mind-config should point to your existing Iterate config checkout containing package.json.")
    package = json.loads(package_file.read_text())
    if not isinstance(package, dict) or not isinstance(package.get("dependencies", {}), dict):
        raise ValueError("Expected a package.json object with a dependencies object in the mind config.")
    source = REPO / "Server" / "mind"
    destination = root / "apps" / "iterate-ios"
    files = {destination / name: (source / name).read_text() for name in MODULES}
    files[destination / "settings.js"] = "export const deployment = " + json.dumps(deployment, indent=2) + ";\n"
    if not replace:
        conflicts = [str(path.relative_to(root)) for path, value in files.items()
                     if path.exists() and path.read_text() != value]
        if conflicts:
            raise ValueError("Existing backend files differ: " + ", ".join(conflicts)
                             + ". Review the changes, then use --replace-backend to update those files.")
    if not (root / "voice.ts").exists():
        files[root / "voice.ts"] = VOICE_SHIM
    deps = package.setdefault("dependencies", {})
    if "@iterate-com/voice" not in deps:
        deps["@iterate-com/voice"] = VOICE_VERSION
        files[package_file] = json.dumps(package, ensure_ascii=False, indent=2) + "\n"
    return files


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--domain", required=True, help="Workspace apex hostname used for universal links")
    parser.add_argument("--control-host", help="OAuth/API hostname (default: iterate.<domain>)")
    parser.add_argument("--dash-host", help="Dash hostname (default: dash.<domain>)")
    parser.add_argument("--mind-id", help="Known mind identity. Omit to discover it over HTTPS.")
    parser.add_argument("--bundle-id", default="org.example.iterate", help="Base iOS bundle ID for all targets")
    parser.add_argument("--team-id", default="", help="Apple Developer team ID for device signing")
    parser.add_argument("--app-id-prefix", help="Apple App ID prefix for universal links if different from the team ID")
    parser.add_argument("--mind-config", type=Path, help="Existing mind config checkout to receive the backend")
    parser.add_argument("--replace-backend", action="store_true", help="Replace differing mobile modules in that checkout")
    args = parser.parse_args(argv)

    apex = hostname(args.domain)
    control = hostname(args.control_host or "iterate." + apex)
    dash = hostname(args.dash_host or "dash." + apex)
    bundle = args.bundle_id
    if "." not in bundle or len(bundle) > 240 or not all(LABEL.fullmatch(label) for label in bundle.split(".")):
        raise ValueError("Supply a reverse-DNS Apple bundle identifier such as com.example.iterate.")
    team = args.team_id.upper()
    if team and not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("The Apple team ID must contain 10 letters or digits.")
    app_prefix = args.app_id_prefix.upper() if args.app_id_prefix else None
    if app_prefix and (not team or not re.fullmatch(r"[A-Z0-9]{10}", app_prefix)):
        raise ValueError("An App ID prefix needs a team ID and must contain 10 letters or digits.")
    pin = checked_mind_id(args.mind_id) if args.mind_id is not None else discover_mind(control)

    if args.replace_backend and args.mind_config is None:
        raise ValueError("--replace-backend requires --mind-config.")
    if args.mind_config is not None:
        root = args.mind_config.expanduser().resolve()
        deployment = dict(apexHost=apex, controlHost=control, dashHost=dash, bundleID=bundle, teamID=team)
        if app_prefix:
            deployment["appIDPrefix"] = app_prefix
        for path, content in backend_files(root, deployment, args.replace_backend).items():
            write_if_changed(path, content)
        print(f"Mobile backend prepared in {root / 'apps' / 'iterate-ios'}.")
        print("Register the hooks in your config entrypoint as shown in Server/README.md before publishing.")

    settings = dict(ITERATE_APEX_HOST=apex, ITERATE_CONTROL_HOST=control, ITERATE_DASH_HOST=dash,
                    ITERATE_MIND_ID=pin, ITERATE_BUNDLE_ID=bundle, ITERATE_TEAM_ID=team)
    xcconfig = "// Generated by scripts/configure.py for this checkout.\n" + "".join(
        f"{key} = {value}\n" for key, value in settings.items())
    write_if_changed(REPO / "Configuration" / "Local.xcconfig", xcconfig, private=True)
    print(f"Configured Iterate.xcodeproj for {control}. Open the Iterate scheme in Xcode.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        sys.exit(f"Setup failed: {error}")
