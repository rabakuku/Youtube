#!/usr/bin/env python3
# filepath: https://github.com/rabakuku/Youtube/blob/main/Video-4-HoneyWall-Live-Deception-SOC/compose/build_honeyfs.py
"""
HoneyWall honeyfs builder (runs once inside the Cowrie 3.1.5 image as uid 999).

1. Loads Cowrie's bundled fs.pickle (the fake Debian filesystem).
2. Copies every file under HONEYFS_SRC into the tree at the same path,
   embedding the bytes so 'ls' and 'cat' inside the decoy look real.
3. Adds the leaked account (svc_backup) to /etc/passwd, /etc/group, /etc/shadow
   and creates its home directory.
4. Writes the result atomically to HONEYFS_OUT (cowrie.cfg [shell] filesystem).

Idempotent: always rebuilds from the bundled pickle, so re-runs never duplicate.
"""
import os
import pickle
import secrets
import stat
import sys
import time

from cowrie.core.resources import open_data_binary

A_NAME, A_TYPE, A_UID, A_GID, A_SIZE, A_MODE, A_CTIME, A_CONTENTS, A_TARGET, A_REALFILE = range(10)
T_LINK, T_DIR, T_FILE = 0, 1, 2

SRC = os.environ.get("HONEYFS_SRC", "/honeywall/honeyfs")
OUT = os.environ.get("HONEYFS_OUT", "/cowrie/cowrie-git/var/lib/cowrie/honeywall-fs.pickle")
USER = os.environ.get("DECOY_LEAKED_USER", "svc_backup")
UID = int(os.environ.get("DECOY_LEAKED_UID", "1001"))
HOME = "/home/" + USER
# Make planted files look a few weeks old
CTIME = int(time.time()) - 23 * 86400


def log(msg):
    print("[honeyfs] " + msg, flush=True)


def child(node, name):
    for c in node[A_CONTENTS]:
        if c[A_NAME] == name:
            return c
    return None


def owner_for(path):
    if path == HOME or path.startswith(HOME + "/"):
        return UID, UID
    return 0, 0


def ensure_dir(tree, path):
    node = tree
    walked = ""
    for part in [p for p in path.split("/") if p]:
        walked += "/" + part
        nxt = child(node, part)
        if nxt is None:
            uid, gid = owner_for(walked)
            mode = stat.S_IFDIR | (0o700 if walked in (HOME, "/root/.aws") else 0o755)
            nxt = [part, T_DIR, uid, gid, 4096, mode, CTIME, [], None, None]
            node[A_CONTENTS].append(nxt)
        elif nxt[A_TYPE] != T_DIR:
            raise SystemExit("[honeyfs] ERROR: " + walked + " exists and is not a directory")
        node = nxt
    return node


def put_file(tree, path, data, mode=0o600):
    parent = ensure_dir(tree, os.path.dirname(path))
    name = os.path.basename(path)
    parent[A_CONTENTS] = [c for c in parent[A_CONTENTS] if c[A_NAME] != name]
    uid, gid = owner_for(path)
    parent[A_CONTENTS].append(
        [name, T_FILE, uid, gid, len(data), stat.S_IFREG | mode, CTIME, data, None, None]
    )


def find(tree, path):
    node = tree
    for part in [p for p in path.split("/") if p]:
        if node[A_TYPE] != T_DIR:
            return None
        node = child(node, part)
        if node is None:
            return None
    return node


def append_line(tree, path, line):
    node = find(tree, path)
    if node is None or not isinstance(node[A_CONTENTS], bytes):
        log("skip " + path + " (no embedded contents)")
        return
    data = node[A_CONTENTS]
    if line.split(b":")[0] + b":" in [l.split(b":")[0] + b":" for l in data.splitlines()]:
        return
    if not data.endswith(b"\n"):
        data += b"\n"
    data += line + b"\n"
    node[A_CONTENTS] = data
    node[A_SIZE] = len(data)


def main():
    with open_data_binary("fs.pickle") as f:
        tree = pickle.load(f)
    log("loaded bundled fs.pickle")

    u = USER.encode()
    ids = str(UID).encode()
    append_line(tree, "/etc/passwd", u + b":x:" + ids + b":" + ids + b":Backup Service,,,:" + HOME.encode() + b":/bin/bash")
    append_line(tree, "/etc/group", u + b":x:" + ids + b":")
    # Random, never-valid crypt-looking hash so 'cat /etc/shadow' looks real on camera
    alphabet = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    fake = "$6$" + "".join(secrets.choice(alphabet) for _ in range(8)) + "$" + "".join(secrets.choice(alphabet) for _ in range(86))
    append_line(tree, "/etc/shadow", u + b":" + fake.encode() + b":19800:0:99999:7:::")
    ensure_dir(tree, HOME)
    log("added user " + USER + " (uid " + str(UID) + ")")

    count = 0
    for root, _dirs, files in os.walk(SRC):
        for fname in sorted(files):
            real = os.path.join(root, fname)
            virt = "/" + os.path.relpath(real, SRC).replace(os.sep, "/")
            with open(real, "rb") as fh:
                data = fh.read()
            put_file(tree, virt, data, 0o600 if "/." in virt or virt.startswith("/root") else 0o640)
            log("planted " + virt + " (" + str(len(data)) + " bytes)")
            count += 1

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    tmp = OUT + ".tmp"
    with open(tmp, "wb") as fh:
        pickle.dump(tree, fh)
    os.replace(tmp, OUT)
    log("wrote " + OUT + " with " + str(count) + " honeytoken file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
