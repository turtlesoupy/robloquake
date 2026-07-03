#!/usr/bin/env python3
"""Upload Quake sound effects as Roblox audio assets via Open Cloud, and
emit assets/soundmap.txt (JSON name -> rbxassetid) which syncs into
ReplicatedStorage.QuakeAssets.soundmap for src/client/sound.luau.

Requirements:
  * An Open Cloud API key with the assets:read/write scopes
    (create.roblox.com/dashboard/credentials), exported as ROBLOX_API_KEY.
  * Your user id (or group id) exported as ROBLOX_USER_ID / ROBLOX_GROUP_ID.

Usage:
  ROBLOX_API_KEY=... ROBLOX_USER_ID=... python3 tools/upload_sounds.py
  python3 tools/upload_sounds.py --limit 5          # try a few first
  python3 tools/upload_sounds.py --resume            # skip already-mapped

Audio uploads may be subject to moderation review; the script polls each
operation until the asset id is granted.
"""

import argparse
import json
import os
import pathlib
import struct
import sys
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
PAK0 = ROOT / "external_assets/quake106/extracted/id1/pak0.pak"
OUT = ROOT / "assets/soundmap.txt"

API = "https://apis.roblox.com/assets/v1"


def pak_files():
    data = PAK0.read_bytes()
    _, dirofs, dirlen = struct.unpack_from("<4sii", data, 0)
    for i in range(dirlen // 64):
        name, filepos, filelen = struct.unpack_from("<56sii", data, dirofs + i * 64)
        name = name.split(b"\0")[0].decode()
        if name.endswith(".wav"):
            yield name, data[filepos : filepos + filelen]


def multipart(fields, files):
    boundary = "----robloquake"
    lines = []
    for key, value in fields.items():
        lines += [f"--{boundary}", f'Content-Disposition: form-data; name="{key}"', "", value]
    for key, (fname, content, ctype) in files.items():
        lines += [
            f"--{boundary}",
            f'Content-Disposition: form-data; name="{key}"; filename="{fname}"',
            f"Content-Type: {ctype}",
            "",
        ]
    body = "\r\n".join(lines).encode() + b"\r\n" + content + f"\r\n--{boundary}--\r\n".encode()
    return body, f"multipart/form-data; boundary={boundary}"


def api(key, url, body=None, ctype=None, method="GET"):
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("x-api-key", key)
    if ctype:
        req.add_header("Content-Type", ctype)
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())


def upload(key, creator, name, wav):
    display = name.replace("/", "_").removesuffix(".wav")
    request = {
        "assetType": "Audio",
        "displayName": f"quake {display}"[:50],
        "description": "Quake sound effect",
        "creationContext": {"creator": creator},
    }
    body, ctype = multipart(
        {"request": json.dumps(request)},
        {"fileContent": (display + ".wav", wav, "audio/wav")},
    )
    op = api(key, API + "/assets", body, ctype, "POST")
    op_path = op["path"]
    for _ in range(60):
        time.sleep(2)
        status = api(key, f"https://apis.roblox.com/assets/v1/{op_path}")
        if status.get("done"):
            return status["response"]["assetId"]
    raise RuntimeError(f"upload of {name} did not complete")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--resume", action="store_true")
    args = ap.parse_args()

    key = os.environ.get("ROBLOX_API_KEY")
    if not key:
        sys.exit("set ROBLOX_API_KEY (Open Cloud key with assets scopes)")
    if os.environ.get("ROBLOX_GROUP_ID"):
        creator = {"groupId": os.environ["ROBLOX_GROUP_ID"]}
    elif os.environ.get("ROBLOX_USER_ID"):
        creator = {"userId": os.environ["ROBLOX_USER_ID"]}
    else:
        sys.exit("set ROBLOX_USER_ID or ROBLOX_GROUP_ID")

    soundmap = {}
    if args.resume and OUT.exists():
        soundmap = json.loads(OUT.read_text())

    todo = [(n, w) for n, w in pak_files() if n not in soundmap]
    if args.limit:
        todo = todo[: args.limit]
    print(f"{len(todo)} wavs to upload ({len(soundmap)} already mapped)")

    for i, (name, wav) in enumerate(todo):
        try:
            asset_id = upload(key, creator, name, wav)
            soundmap[name] = f"rbxassetid://{asset_id}"
            print(f"[{i + 1}/{len(todo)}] {name} -> {asset_id}")
        except Exception as e:  # keep going; moderation can reject items
            print(f"[{i + 1}/{len(todo)}] {name} FAILED: {e}")
        OUT.parent.mkdir(exist_ok=True)
        OUT.write_text(json.dumps(soundmap, indent=0))

    print(f"wrote {OUT} ({len(soundmap)} entries)")


if __name__ == "__main__":
    main()
