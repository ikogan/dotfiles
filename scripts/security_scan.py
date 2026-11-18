#!/usr/bin/env python3
"""Scan hosts, container runtimes, and Kubernetes nodes for security exposure.

Certificate check: keystores (certificates plus private keys, e.g. PKCS#12 and
JKS) and trust stores (certificates only, e.g. cacerts, PEM bundles, NSS
cert9.db) that contain the eMudhra intermediate CAs compromised in October 2026
(see https://thehackernews.com/2026/10/eight-emudhra-ca-keys-compromised.html).

Matching uses two signals:
  * the certificate common name (CN), and
  * the SHA-256 of the SubjectPublicKeyInfo, so Sectigo cross-signed copies and
    any renamed certificate carrying the same key are also caught.

Stores are inspected by parsing PEM/DER certificates directly, with openssl for
PKCS#7 and PKCS#12 and keytool for JKS/JCEKS (passwords tried from a list).
Anything that cannot be parsed is still checked by searching the raw bytes for
the CA names (e.g. NSS cert9.db).

Runtime versions (PHP and Node.js) are read from headers, package databases,
and binary version strings, then compared with the fixed releases:
  * PHP: CVE-2026-109618 / CVE-2026-109619 ("php2shell"), fixed in
    8.5.12, 8.4.27, 8.3.36, 8.2.35. Branches 8.1 and older have no fix.
  * Node.js: October 21, 2026 security releases (CVE-2026-111497 and others),
    fixed in 26.12.1, 24.22.1, 22.23.4. Other lines are end-of-life with no fix.
Distro packages may carry backported fixes without a new upstream version, so
a package-database hit is a prompt to check the vendor advisory.

Targets (at least one is required):
  --local                 this host (standard certificate locations, or --path/--all)
  --ssh HOST              a remote host over ssh
  --container-runtime R   running docker or podman containers on this host
  --k8s                   every node in the cluster, via a debug pod on each node.
                          Reads the node's container storage and kubelet volumes
                          from the host filesystem, so the containers don't need
                          tar or anything else. A PersistentVolume mounted on
                          several nodes is scanned on one of them only.
                          Requires --image.

Examples:
  security_scan.py --local                           # this host, standard locations
  security_scan.py --local --all                     # this host, entire filesystem
  security_scan.py --ssh root@web01 --sudo           # remote host
  security_scan.py --container-runtime docker        # running docker containers
  security_scan.py --k8s --image python:3.14-slim    # all nodes, debug pods in kube-system
  security_scan.py --k8s --image python:3.14-slim -l node-role.kubernetes.io/worker
  security_scan.py --k8s --image python:3.14-slim --node worker-1 --json

  security_scan.py --local --check runtimes          # only PHP/Node.js versions

Requires openssl. Optional: keytool, kubectl (or oc), docker/podman, ssh.
Exit codes: 0 clean, 1 only related roots found, 2 compromised material found,
3 usage error, 4 vulnerable or unknown runtime version found (and no compromised material),
5 incomplete scan (a target could not be scanned) with no findings,
6 existing scanner pods were found and not deleted (the scan did not run).
"""

import argparse
import base64
import concurrent.futures
import contextlib
import curses
from collections import Counter, deque
import hashlib
import json
import os
import posixpath
import re
import secrets
import shlex
import signal
import shutil
import subprocess
import sys
import tarfile
import threading
import time

COMPROMISED_CAS = [
    "EM DV TLS CA - G3B",
    "EM DV TLS CA - G3C",
    "EM OV TLS CA - G3B",
    "EM OV TLS CA - G3C",
    "EM EV TLS CA - G3B",
    "EM EV TLS CA - G3C",
    "EM OV CS CA - G3B",
    "EM OV CS CA - G3C",
    "emSign ECC Root CA - G3",
]

RELATED_CAS = [
    "emSign Root TLS CA - G3",
    "emSign Root CA - G1",
    "AAA Certificate Services",
]

DEFAULT_ROOTS = ["/etc", "/usr/share", "/usr/lib", "/usr/local", "/opt",
                 "/var/lib", "/srv", "/home", "/root"]
SKIP_PATHS = ("/var/lib/docker/", "/var/lib/containers/", "/var/lib/podman/",
              "/.local/share/containers/")
DEFAULT_PASSWORDS = ["", "changeit", "changeme", "password"]
DEBUG_NAMESPACE = "kube-system"
NODE_ROOT = "/host"
STARTUP_TIMEOUT = 300
MANAGED_LABEL = "wraithwatch.io/managed"
NODE_LABEL = "wraithwatch.io/node"
POD_PREFIX = "wraithwatch-security-scan"
STARTUP_FAILURE_REASONS = {"ErrImagePull", "ImagePullBackOff", "ErrImageNeverPull", "InvalidImageName",
                           "ImageInspectError", "CreateContainerError", "CreateContainerConfigError",
                           "RunContainerError", "CrashLoopBackOff"}
MAX_FILE_SIZE = 32 * 1024 * 1024
# File bytes held in memory at once, across all scanning threads. A runtime binary (512 MiB)
# must fit alone, so this is the most a scan can hold; the k8s debug pod limit is sized above it.
READ_BUDGET_BYTES = 640 * 1024 * 1024
STREAM_IDLE_TIMEOUT = 600  # seconds a container export may go silent before it is killed
CONTAINER_MAX_SECONDS = 7200  # total time allowed for one container export, however steadily it runs
WARNINGS = []  # coverage problems found while scanning (e.g. a keytool that cannot read -storepass:env)
ACTIVE_EXPORTS = set()  # running container exports, killed if the scan aborts
REAP_TIMEOUT = 30  # seconds a child may take to exit after its output has ended
STALL_TIMEOUT = 300  # seconds a root's scan may go without progress before the whole scan is aborted
SSH_TIMEOUT = 3600
STDERR_TAIL_BYTES = 8192
HEARTBEAT = False  # scan processes write a line per file so the parent can see progress and detect stalls
STATS = {"files": 0, "bytes": 0}  # what a scan process has read so far (reported back to the parent)
TOTALS = {"files": 0, "bytes": 0}  # what this process's child scans have read, summed
COVERAGE = {"nodes_total": 0, "nodes_scanned": 0}  # cluster nodes asked for vs. nodes whose scan finished
NODE_IDLE_TIMEOUT = 900  # seconds a debug pod may go without any output before the scan gives up on it
NODE_TIMEOUT = 4 * 3600  # default overall limit for one node; --node-timeout overrides it
PSEUDO_FS = ("/proc", "/sys", "/dev")
PSEUDO_FSTYPES = frozenset({
    "proc", "sysfs", "devtmpfs", "devpts", "cgroup", "cgroup2", "securityfs", "debugfs", "tracefs",
    "pstore", "bpf", "mqueue", "configfs", "fusectl", "autofs", "nsfs", "rpc_pipefs", "binfmt_misc", "efivarfs"})
# The token file of a projected service account volume or a legacy <sa>-token-<hash> secret. Only the
# token is skipped: ca.crt beside it can hold a CA bundle that matters.
CREDENTIAL_RE = re.compile(r"/kubernetes\.io~projected/kube-api-access-[^/]*/token$|/kubernetes\.io~secret/[^/]*-token-[^/]*/token$")
DEBUG_CONTAINER = "scanner"
DELETE_BATCH = 100  # pod names per kubectl delete, to keep the command line well under ARG_MAX
HOST_MOUNTINFO = "/proc/1/mountinfo"  # PID 1 is the host's init (hostPID), so this is the host mount table
NETWORK_FS = ("nfs", "nfs4", "ceph")  # used only when a mount's source says nothing about where it lives
PV_PLUGIN_DIRS = {f"kubernetes.io~{p}" for p in (
    "csi", "nfs", "cephfs", "glusterfs", "iscsi", "fc", "rbd", "cinder",
    "azure-file", "azure-disk", "aws-ebs", "gce-pd", "local-volume")}
JKS_MAGIC = b"\xfe\xed\xfe\xed"
JCEKS_MAGIC = b"\xce\xca\xce\xca"
PKCS12_OID = b"\x2a\x86\x48\x86\xf7\x0d\x01\x0c"
CN_OID = b"\x06\x03\x55\x04\x03"
PKCS12_EXTS = (".p12", ".pfx", ".pkcs12")
PKCS7_EXTS = (".p7b", ".p7c")
DER_EXTS = (".der", ".cer", ".crt")
RAW_NAMES = ("cacerts", "cert8.db", "cert9.db", "cert.db")
RAW_EXTS = (".jks", ".jceks", ".bks", ".keystore", ".truststore") + PKCS12_EXTS
# Never opened: media is large and holds no certificate store or runtime version, and archives and
# disk images would be unpacked by nothing here, so their contents are not inspected.
SKIPPED_EXTS = frozenset((
    ".mp4", ".mkv", ".avi", ".mov", ".wmv", ".m4v", ".webm", ".mpg", ".mpeg", ".ts", ".m2ts", ".flv",
    ".mp3", ".flac", ".m4a", ".aac", ".ogg", ".oga", ".opus", ".wav",
    ".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".tif", ".tiff", ".heic", ".heif", ".psd",
    ".zip", ".tar", ".tgz", ".gz", ".bz2", ".xz", ".zst", ".7z", ".rar", ".iso", ".img", ".dmg"))


def skipped_type(path):
    return os.path.splitext(path)[1].lower() in SKIPPED_EXTS
ALL_NAMES = COMPROMISED_CAS + RELATED_CAS

PHP_FIXED = {(8, 5): (8, 5, 12), (8, 4): (8, 4, 27), (8, 3): (8, 3, 36), (8, 2): (8, 2, 35)}
NODE_FIXED = {26: (26, 12, 1), 24: (24, 22, 1), 22: (22, 23, 4)}
RUNTIME_BINARY_NAMES = re.compile(r"^(php|php-fpm|node)$")
RUNTIME_MAX_FILE_SIZE = 512 * 1024 * 1024
PEM_CERT_RE = re.compile(rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", re.S)


def run_capture(cmd, data=None, timeout=120, env=None):
    """(returncode, stdout, stderr). The returncode is None if the command could not start, timed out,
    or would not die: subprocess.run() waits for a killed child without a bound, which a child stuck
    in an uninterruptible read never honours."""
    try:
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE if data is not None else subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    except OSError:
        return None, b"", b""
    try:
        out, err = proc.communicate(data, timeout=timeout)
    except subprocess.TimeoutExpired:
        killed(f"{cmd[0]} (pid {proc.pid})", f"still running after {timeout}s")
        proc.kill()
        try:
            out, err = proc.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            return None, b"", b""
        return None, out, err
    return proc.returncode, out, err


def run(cmd, data=None, timeout=120, env=None):
    rc, out, _ = run_capture(cmd, data, timeout, env)
    return out if rc == 0 else None


class ByteBudget:
    """Blocks readers while the bytes already reserved, across threads, would exceed the limit."""

    def __init__(self, limit):
        self.limit = limit
        self.used = 0
        self.cond = threading.Condition()

    @contextlib.contextmanager
    def reserve(self, size):
        size = min(size, self.limit)
        with self.cond:
            self.cond.wait_for(lambda: self.used + size <= self.limit)
            self.used += size
        try:
            yield
        finally:
            with self.cond:
                self.used -= size
                self.cond.notify_all()


READ_BUDGET = ByteBudget(READ_BUDGET_BYTES)


def pem_to_der(pem):
    try:
        return base64.b64decode(re.sub(rb"-----[^-]*-----|\s+", b"", pem), validate=True)
    except ValueError:
        return None


def tlv(data, pos):
    """Return (tag, element_start, value_start, element_end) for the DER element at pos."""
    tag = data[pos]
    length = data[pos + 1]
    value = pos + 2
    if length & 0x80:
        n = length & 0x7F
        length = int.from_bytes(data[value:value + n], "big")
        value += n
    return tag, pos, value, value + length


def parse_cert(der):
    """Return (common_name, spki_sha256) for a DER certificate, or None if it is not one."""
    if not der:
        return None
    try:
        if der[0] != 0x30 or tlv(der, 0)[3] != len(der):
            return None
        _, _, pos, _ = tlv(der, tlv(der, 0)[2])
        if der[pos] == 0xA0:
            pos = tlv(der, pos)[3]
        for _ in range(4):  # serial, signature algorithm, issuer, validity
            pos = tlv(der, pos)[3]
        _, subj_start, _, subj_end = tlv(der, pos)
        _, spki_start, _, spki_end = tlv(der, subj_end)
    except IndexError:
        return None
    subject = der[subj_start:subj_end]
    i = subject.find(CN_OID)
    cn = ""
    if i >= 0:
        _, _, vs, end = tlv(subject, i + len(CN_OID))
        cn = subject[vs:end].decode("utf-8", errors="replace")
    return cn, hashlib.sha256(der[spki_start:spki_end]).hexdigest()


# Keystores are piped to the tools on stdin (/dev/stdin), so they never touch the filesystem.
# Passwords go in the environment, not argv: /proc/<pid>/cmdline is world-readable, environ is not.
PASSWORD_ENV = "WRAITH_STORE_PASSWORD"


def store_env(pw):
    return {**os.environ, PASSWORD_ENV: pw}


def pem_blocks(data):
    # Every certificate in the file: the list is at most as large as the file, which is size-limited.
    return PEM_CERT_RE.findall(data)


def keytool_certs(data, store_type, passwords):
    for pw in passwords:
        rc, out, err = run_capture(["keytool", "-list", "-rfc", "-keystore", "/dev/stdin",
                                    "-storetype", store_type, "-storepass:env", PASSWORD_ENV],
                                   data, env=store_env(pw))
        if rc == 0:
            return pem_blocks(out)
        if b"Illegal option" in err or b"Unrecognized option" in err:
            # Older JDKs lack the :env modifier. Failing here, rather than retrying, keeps the password
            # off the command line, and the gap is reported instead of silently falling back.
            note = (f"keytool does not accept -storepass:env (JDK too old): {store_type} stores "
                    "are checked by raw byte search only")
            if note not in WARNINGS:
                WARNINGS.append(note)
            return None
    return None


def pkcs12_certs(data, passwords):
    for pw in passwords:
        for extra in ([], ["-legacy"]):
            out = run(["openssl", "pkcs12", "-in", "/dev/stdin", "-nokeys",
                       "-passin", f"env:{PASSWORD_ENV}"] + extra, data, env=store_env(pw))
            if out is not None:
                return pem_blocks(out)
    return None


def pkcs7_certs(data):
    for fmt in ("PEM", "DER"):
        out = run(["openssl", "pkcs7", "-print_certs", "-inform", fmt], data)
        if out is not None:
            return pem_blocks(out)
    return None


def inspect_file(location, path, data, passwords):
    if not SCAN_CERTS:
        return runtime_records(location, path, data)
    name = os.path.basename(path).lower()
    ext = os.path.splitext(name)[1]
    ders = None
    if data[:4] in (JKS_MAGIC, JCEKS_MAGIC):
        store_type = "JKS" if data[:4] == JKS_MAGIC else "JCEKS"
        pems = keytool_certs(data, store_type, passwords)
        ders = [pem_to_der(p) for p in pems or []]
    elif ext in PKCS12_EXTS or PKCS12_OID in data[:4096]:
        pems = pkcs12_certs(data, passwords)
        ders = [pem_to_der(p) for p in pems or []]
    elif b"-----BEGIN CERTIFICATE-----" in data:
        ders = [pem_to_der(p) for p in pem_blocks(data)]
    elif ext in PKCS7_EXTS:
        pems = pkcs7_certs(data)
        ders = [pem_to_der(p) for p in pems or []]
    elif ext in DER_EXTS and len(data) < 65536:
        ders = [data]

    records = []
    for der in ders or []:
        info = parse_cert(der)
        if info:
            records.append({"location": location, "method": "parsed",
                            "subject": info[0], "spki": info[1], "names": []})
    raw_candidate = (name in RAW_NAMES or ext in RAW_EXTS
                     or data[:4] in (JKS_MAGIC, JCEKS_MAGIC))
    if not records and raw_candidate:
        names = [n for n in ALL_NAMES if n.encode() in data]
        if names:
            records.append({"location": location, "method": "raw",
                            "subject": None, "spki": None, "names": names})
    if SCAN_RUNTIMES:
        records += runtime_records(location, path, data)
    return records


def dominant_version(pattern, data, min_major=0):
    """(version, ambiguous) for the most frequent capture of `pattern` in the whole file.

    Every match is counted but only distinct values are kept, so memory follows the number of
    distinct versions, not matches. `ambiguous` is set when no version is a clear majority, which
    happens when a bundled dependency carries version strings of its own.
    """
    counts = Counter(m.group(1) for m in re.finditer(pattern, data))
    if min_major:
        counts = Counter({v: n for v, n in counts.items() if int(v.split(b".")[0]) >= min_major})
    if not counts:
        return None, False
    top, n = counts.most_common(1)[0]
    return top.decode(), n * 2 <= sum(counts.values())


def runtime_relevant(path):
    """Files that can carry a PHP/Node.js version; with --check runtimes, nothing else is read."""
    return (RUNTIME_BINARY_NAMES.match(os.path.basename(path)) is not None
            or path.endswith(("main/php_version.h", "include/node/node_version.h", "var/lib/dpkg/status")))


def runtime_records(location, path, data):
    """Version records for PHP and Node.js, from headers, binaries, or the dpkg database."""
    name = os.path.basename(path)
    found = []

    def add(runtime, version, source, ambiguous=False):
        found.append({"location": location, "method": "version", "runtime": runtime,
                      "version": version, "source": source, "ambiguous": ambiguous,
                      "subject": None, "spki": None, "names": []})

    if path.endswith("main/php_version.h"):
        m = re.search(rb'#define PHP_VERSION "(\d+\.\d+\.\d+)"', data)
        if m:
            add("php", m.group(1).decode(), "php_version.h")
    elif path.endswith("include/node/node_version.h"):
        parts = dict(re.findall(rb"#define NODE_(MAJOR|MINOR|PATCH)_VERSION (\d+)", data))
        if len(parts) == 3:
            add("node", ".".join(parts[k].decode() for k in (b"MAJOR", b"MINOR", b"PATCH")),
                "node_version.h")
    elif name in ("php", "php-fpm"):
        version, ambiguous = dominant_version(rb"X-Powered-By: PHP/(\d+\.\d+\.\d+)", data)
        if version:
            add("php", version, "binary", ambiguous)
    elif name == "node":
        version, ambiguous = dominant_version(rb"\bv(\d+\.\d+\.\d+)\b", data, min_major=18)
        if version:
            add("node", version, "binary", ambiguous)
    elif path.endswith("var/lib/dpkg/status"):
        for block in data.decode(errors="replace").split("\n\n"):
            pkg = re.search(r"^Package: ((?:php|nodejs)[\w.+-]*)$", block, re.M)
            status = re.search(r"^Status: (.*)$", block, re.M)
            ver = re.search(r"^Version: (?:\d+:)?(\d+\.\d+\.\d+)", block, re.M)
            if pkg and ver and status and status.group(1).endswith("installed"):
                runtime = "node" if pkg.group(1).startswith("nodejs") else "php"
                add(runtime, ver.group(1), f"dpkg:{pkg.group(1)}")
    return found


def assess_runtime(runtime, version, ambiguous=False):
    """Return (status, detail) for a version: OK, VULNERABLE, or UNKNOWN."""
    if ambiguous:
        return "UNKNOWN", "several different version strings in the binary; the runtime version is not clear"
    parts = tuple(int(x) for x in version.split("."))
    if runtime == "php":
        line = parts[:2]
        if line in PHP_FIXED:
            fixed = ".".join(map(str, PHP_FIXED[line]))
            if parts >= PHP_FIXED[line]:
                return "OK", f"fixed in {fixed}"
            return "VULNERABLE", f"fixed in {fixed}"
        if line < max(PHP_FIXED):
            return "VULNERABLE", "branch has no fixed release; upgrade to 8.2 or newer"
        return "UNKNOWN", "branch not in the fixed-version table"
    major = parts[0]
    if major in NODE_FIXED:
        fixed = ".".join(map(str, NODE_FIXED[major]))
        if parts >= NODE_FIXED[major]:
            return "OK", f"fixed in {fixed}"
        return "VULNERABLE", f"fixed in {fixed}"
    if major < max(NODE_FIXED):
        return "VULNERABLE", "end-of-life line with no fix; upgrade to 22.x, 24.x, or 26.x"
    return "UNKNOWN", "line not in the fixed-version table"


def runtime_findings(records):
    findings = []
    for r in records:
        if r["method"] != "version":
            continue
        status, detail = assess_runtime(r["runtime"], r["version"], r.get("ambiguous", False))
        findings.append({"kind": "runtime", "status": status, "location": r["location"],
                         "runtime": r["runtime"], "version": r["version"],
                         "source": r["source"], "detail": detail})
    return findings


def is_pseudo(path):
    return any(path == p or path.startswith(p + "/") for p in PSEUDO_FS)


def pseudo_mountpoints(prefix, mountinfo):
    """Mountpoints (as local paths under `prefix`) of kernel pseudo-filesystems, from the mount table.

    Matching by mount table catches proc/sys/dev bind-mounted anywhere, which path text cannot.
    """
    return frozenset(os.path.normpath(prefix + m["mountpoint"])
                     for m in read_mounts(mountinfo) if m["fstype"] in PSEUDO_FSTYPES)


def in_any(path, places):
    return any(path == p or path.startswith(p + "/") for p in places)


def is_credential(path):
    """Service account tokens: JWTs that never hold certificates, so they are not read."""
    return CREDENTIAL_RE.search(path) is not None


def size_limit(path):
    return RUNTIME_MAX_FILE_SIZE if RUNTIME_BINARY_NAMES.match(os.path.basename(path)) else MAX_FILE_SIZE


def is_skipped(path):
    return any(s in path + "/" for s in SKIP_PATHS)


def dir_key(path):
    """Identity of a directory. Bind mounts of the same directory share it, so each is walked once."""
    try:
        st = os.lstat(path)
    except OSError:
        return None
    return (st.st_dev, st.st_ino)


def prune_dirs(dirpath, dirnames, skip, seen, skip_paths, pseudo):
    """Keep only the subdirectories a walk should descend into (edits dirnames in place)."""
    kept = []
    for d in dirnames:
        path = os.path.join(dirpath, d)
        if is_pseudo(path) or (skip and is_skipped(path)) or path in pseudo or is_credential(path):
            continue
        if path in skip_paths or live_covers(path):
            continue
        if seen is not None and not os.path.islink(path):
            key = dir_key(path)
            if key in seen:
                continue
            if key:
                seen.add(key)
        kept.append(d)
    dirnames[:] = kept


def count_files(root, skip, seen, skip_paths, pseudo):
    """How many files iter_local will consider under root. Metadata only, so it is cheap; a total for the bar."""
    if in_any(root, pseudo) or not os.path.isdir(root) or root in live_ignored():
        return 0
    n = 0
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        if HEARTBEAT:
            sys.stderr.write("C " + dirpath.replace("\n", "\\n") + "\n")
            sys.stderr.flush()
        prune_dirs(dirpath, dirnames, skip, seen, skip_paths, pseudo)
        for fn in filenames:
            # No stat() per file: os.walk already knows each entry's type from the directory listing.
            # A stat reads the inode, which is a random disk read per file on a cold network block device.
            # Symlinks and devices in `filenames` make this a slight overcount, which is fine for a bar.
            path = os.path.join(dirpath, fn)
            if path in pseudo or is_credential(path) or skipped_type(path) or (not SCAN_CERTS and not runtime_relevant(path)):
                continue
            n += 1
            if HEARTBEAT and n % 250 == 0:
                COUNT_STATE["n"] = n
                sys.stderr.write(f"K {n}\n")  # running count, so the bar moves during a long walk
                sys.stderr.flush()
    return n


def iter_local(root, skip=True, seen=None, skip_paths=frozenset(), pseudo=frozenset()):
    count = 0
    tty = sys.stderr.isatty()
    if in_any(root, pseudo) or root in live_ignored():
        return
    if seen is not None:
        key = dir_key(root)
        if key in seen:
            return
        if key:
            seen.add(key)
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        if HEARTBEAT:
            sys.stderr.write("C " + dirpath.replace("\n", "\\n") + "\n")
            sys.stderr.flush()
        prune_dirs(dirpath, dirnames, skip, seen, skip_paths, pseudo)
        for fn in filenames:
            if live_covers(dirpath):
                break  # ignored while this directory's files were being read
            path = os.path.join(dirpath, fn)
            if skipped_type(path):
                continue
            count += 1
            if HEARTBEAT:
                # One line per file: the parent counts them (progress) and sees the last one (where it stopped).
                sys.stderr.write("F " + path.replace("\n", "\\n") + "\n")
                sys.stderr.flush()
                STATS["files"] += 1
            if tty and count % 500 == 0:
                sys.stderr.write(f"\rscanned {count} files, at {dirpath[:60]:<60}")
                sys.stderr.flush()
            if path in pseudo or is_credential(path) or (not SCAN_CERTS and not runtime_relevant(path)):
                continue
            try:
                if os.path.islink(path) or not os.path.isfile(path):
                    continue
                size = os.path.getsize(path)
                if size > size_limit(path):
                    continue
            except OSError:
                continue
            with READ_BUDGET.reserve(size):
                try:
                    with open(path, "rb") as f:
                        data = f.read()
                        drop_cache(f)
                except OSError:
                    continue
                if HEARTBEAT:
                    STATS["bytes"] += len(data)
                yield path, data
    if tty:
        sys.stderr.write("\r" + " " * 100 + "\r")


def iter_tar(fileobj):
    with tarfile.open(fileobj=fileobj, mode="r|*") as tar:
        for member in tar:
            if not member.isfile():
                continue
            path = "/" + re.sub(r"^(\./|/)+", "", member.name)
            if is_pseudo(path) or skipped_type(path) or member.size > size_limit(path):
                continue
            if not SCAN_CERTS and not runtime_relevant(path):
                continue
            handle = tar.extractfile(member)
            if handle is None:
                continue
            with READ_BUDGET.reserve(member.size):
                yield path, handle.read()


def scan_entries(entries, label, passwords, into=None):
    """Inspect each entry; results go into `into` as they are found, so a failure part-way keeps them."""
    records = [] if into is None else into
    for path, data in entries:
        location = f"{label}:{path}" if label else path
        records += inspect_file(location, path, data, passwords)
    return records


class WaitTracker:
    """Wraps a child's stdout and records when a read is blocked waiting on the child."""

    def __init__(self, f):
        self.f = f
        self.waiting_since = None
        self.total = 0

    def read(self, n=-1):
        self.waiting_since = time.monotonic()
        try:
            chunk = self.f.read(n)
            self.total += len(chunk)
            return chunk
        finally:
            self.waiting_since = None


def drain(pipe, keep, tail):
    """Read a pipe to EOF, keeping only its last `keep` bytes so the child never blocks on it."""
    for chunk in iter(lambda: pipe.read(65536), b""):
        tail += chunk
        del tail[:-keep]


def watch_stall(proc, reader, idle, stop, state):
    deadline = time.monotonic() + CONTAINER_MAX_SECONDS
    while not stop.wait(1):
        now = time.monotonic()
        since = reader.waiting_since
        if since is not None and now - since > idle:
            state["stalled"] = True
            killed(f"container export (pid {proc.pid})", f"silent for over {idle}s")
            proc.kill()
            return
        if now > deadline:
            state["too_long"] = True
            killed(f"container export (pid {proc.pid})", f"ran longer than {CONTAINER_MAX_SECONDS}s")
            proc.kill()
            return


def reap(proc):
    """Exit status of a child whose output has ended, or None if it would not exit (see run_capture)."""
    try:
        return proc.wait(timeout=REAP_TIMEOUT)
    except subprocess.TimeoutExpired:
        killed(f"container export (pid {proc.pid})", "did not exit after its output ended")
        proc.kill()
        try:
            return proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            return None


def scan_stream(cmd, label, passwords):
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            stdin=subprocess.DEVNULL)
    stdout = WaitTracker(proc.stdout)
    stderr_tail = bytearray()
    stop = threading.Event()
    state = {"stalled": False, "too_long": False}
    ACTIVE_EXPORTS.add(proc)
    drainer = threading.Thread(target=drain, args=(proc.stderr, STDERR_TAIL_BYTES, stderr_tail), daemon=True)
    watcher = threading.Thread(target=watch_stall, args=(proc, stdout, STREAM_IDLE_TIMEOUT, stop, state),
                               daemon=True)
    drainer.start()
    watcher.start()
    started = time.monotonic()
    note(f"{label}: exporting")
    records, error = [], None
    try:
        scan_entries(iter_tar(stdout), label, passwords, into=records)
    except Exception as exc:
        error = exc
    finally:
        stop.set()
        proc.stdout.close()
        rc = reap(proc)
        ACTIVE_EXPORTS.discard(proc)
        drainer.join(timeout=10)
        watcher.join(timeout=10)
    note(f"{label}: export ended after {time.monotonic() - started:.0f}s, "
         f"{stdout.total / 2**20:.1f} MiB read, {len(records)} record(s)")
    if state["stalled"]:
        raise ScanStalled(f"{label}: no output for {STREAM_IDLE_TIMEOUT}s; the container runtime is not responding",
                          partial=records)
    if state["too_long"]:
        raise ScanFailed(f"{label}: export ran longer than {CONTAINER_MAX_SECONDS}s", partial=records)
    if rc is None:
        raise ScanFailed(f"{label}: export process did not exit after its output ended", partial=records)
    if rc != 0:
        lines = [line.strip("\x00 \t") for line in stderr_tail.decode(errors="replace").splitlines()]
        last = next((line for line in reversed(lines) if line), f"exit {rc}")
        raise ScanFailed(f"{label}: {last}", partial=records)
    if error is not None:
        raise ScanFailed(f"{label}: stream could not be read: {error}", partial=records)
    return records, []


def run_jobs(jobs, passwords, workers):
    """Scan containers in parallel. The first failure terminates the scan: queued exports are cancelled
    and running ones killed. Everything found so far, including what the killed exports had already
    read, is kept in the ScanFailed raised for the caller to report."""
    records, failure, failed = [], None, None
    ex = concurrent.futures.ThreadPoolExecutor(max_workers=workers)
    futures = {ex.submit(scan_stream, cmd, label, passwords): label for cmd, label in jobs}
    consumed = set()
    for fut in concurrent.futures.as_completed(futures):
        try:
            r, _ = fut.result()
        except ScanFailed as exc:
            failure, failed = exc, fut
            break
        except Exception as exc:
            failure, failed = ScanFailed(f"{futures[fut]}: {exc}"), fut
            break
        records += r
        consumed.add(fut)
    if failure is None:
        ex.shutdown(wait=True)
        return records, []
    ex.shutdown(wait=False, cancel_futures=True)
    for proc in list(ACTIVE_EXPORTS):
        proc.kill()
    concurrent.futures.wait(futures, timeout=15)
    partial = records + failure.partial
    for fut in futures:
        if fut in consumed or fut is failed or not fut.done() or fut.cancelled():
            continue
        exc = fut.exception()
        if exc is None:
            partial += fut.result()[0]
        elif isinstance(exc, ScanFailed):
            partial += exc.partial
    raise type(failure)(str(failure), partial=partial)


class ScanFailed(RuntimeError):
    """The scan cannot complete, so it is terminated. `partial` holds the records found before the failure;
    they are reported, marked incomplete, rather than thrown away."""

    def __init__(self, message, partial=()):
        super().__init__(message)
        self.partial = list(partial)


class ScanStalled(ScanFailed):
    """A filesystem or container runtime stopped responding."""


def terminal_width():
    # Emoji take two columns but count as one character, so keep a margin.
    return shutil.get_terminal_size((120, 24)).columns - 4


def fit(line):
    cols = terminal_width()
    return line if len(line) <= cols else line[:cols - 1] + "…"


class Board:
    """Progress for the operator: one bar per target, redrawn in place on a terminal.

    Log lines go through say(), which clears the bars, prints the line, and redraws them, so the
    two never interleave. Without a terminal (CI logs) there are no redraws: a line is printed each
    time a target moves on by 10% or changes phase.
    """

    def __init__(self):
        self.targets = {}
        self.questions = []  # open questions for the operator, drawn at the bottom
        self.ignored = []  # paths the operator has ignored, so the list stays visible after an ignore
        self.drawn = 0
        self.lock = threading.RLock()
        self.tty = sys.stderr.isatty()
        self.screen = None  # the curses screen, once start_ui has taken the terminal
        self.ui_running = False
        self.ui_thread = None
        self.log = deque(maxlen=5000)  # log lines shown in the panel's log pane
        self.status = ""  # the result of the last action, shown in the panel
        self.selected = 0  # index of the question the cursor is on

    def ask(self, items):
        """items: (number, path, suffix) for each open question, oldest first."""
        with self.lock:
            self.questions = list(items)
            self.selected = min(self.selected, max(0, len(self.questions) - 1))
            if self.screen is None and self.tty:
                self._redraw()

    def set(self, name, **fields):
        with self.lock:
            st = self.targets.setdefault(name, {"phase": "waiting", "done": 0, "total": None,
                                                "started": time.monotonic(), "milestone": -1})
            if fields.get("phase") == "scanning" and st["phase"] != "scanning":
                st["started"] = time.monotonic()  # the rate, and so the ETA, is measured from here
            st.update(fields)
            if self.screen is None:
                if self.tty:
                    self._redraw()
                else:
                    self._log_milestone(name, st)

    def say(self, text):
        with self.lock:
            line = f"{time.strftime('%H:%M:%S')} {text}"
            if self.screen is not None:
                self.log.append(line)  # the panel draws it
                return
            if self.tty and self.drawn:
                sys.stderr.write(f"\x1b[{self.drawn}A\x1b[J")
            sys.stderr.write(line + "\n")
            self.drawn = 0
            if self.tty:
                self._redraw()
            sys.stderr.flush()

    def start_ui(self):
        """Takes over the terminal: the log above, the open questions in the middle, progress at the bottom.
        Only the UI thread touches the screen; the scan threads change the data and the log."""
        if self.screen is not None or not (sys.stdin.isatty() and sys.stdout.isatty()):
            return
        self.screen = curses.initscr()
        curses.noecho()
        curses.cbreak()
        self.screen.keypad(True)
        self.screen.timeout(200)  # getch returns every 200 ms, so the panel refreshes even when idle
        try:
            curses.curs_set(0)
        except curses.error:
            pass
        self.ui_running = True
        self.ui_thread = threading.Thread(target=self._ui_main, daemon=True)
        self.ui_thread.start()

    def stop_ui(self):
        if self.screen is None:
            return
        self.ui_running = False
        self.ui_thread.join(timeout=3)
        with self.lock:
            curses.endwin()
            self.screen = None
            kept = list(self.log)
        # The panel's log is gone once the terminal is restored, so print it into the scrollback.
        for line in kept:
            sys.stderr.write(line + "\n")
        sys.stderr.flush()

    def _ui_main(self):
        while self.ui_running:
            with self.lock:
                self._draw()
            key = self.screen.getch()
            if key != -1:
                with self.lock:
                    self._key(key)

    def _key(self, key):
        if key in (curses.KEY_UP, ord("k")):
            self.selected = max(0, self.selected - 1)
        elif key in (curses.KEY_DOWN, ord("j")):
            self.selected = min(max(0, len(self.questions) - 1), self.selected + 1)
        elif key in (curses.KEY_ENTER, 10, 13) and self.questions:
            n, path, _ = self.questions[self.selected]
            self.status = f"ignoring {path}…"
            # Ignoring signals processes and can wait on kubectl, so it runs off the UI thread.
            threading.Thread(target=IGNORER.ignore, args=(n,), daemon=True).start()

    def _draw(self):
        scr = self.screen
        scr.erase()
        h, w = scr.getmaxyx()
        bars = ([self._overall()] if self.targets else []) + [self._render(name, st) for name, st in self.targets.items()]
        panel = []  # (text, attribute), top to bottom
        if self.questions:
            shown_n = min(len(self.questions), max(1, h // 4))
            start = min(max(0, self.selected - shown_n + 1), len(self.questions) - shown_n)
            above, below = start, len(self.questions) - start - shown_n
            hint = "↑/↓ choose, Enter ignores it and everything under it"
            more = f"  ({above} above, {below} below)" if above or below else ""
            panel.append((f"❓ Open questions: {hint}{more}", curses.A_BOLD))
            for i in range(start, start + shown_n):
                n, path, suffix = self.questions[i]
                panel.append((self._question((n, path, suffix)),
                              curses.A_REVERSE if i == self.selected else curses.A_NORMAL))
        if self.ignored:
            panel.append((f"⏭️  ignored so far: {', '.join(self.ignored)}", curses.A_NORMAL))
        panel.append((self.status or "Keys: ↑/↓ choose a question, Enter ignores it. The scan keeps running.",
                      curses.A_DIM))
        log_rows = h - len(bars) - len(panel) - 1
        shown_log = list(self.log)[-log_rows:] if log_rows > 0 else []
        rows = [(line, curses.A_NORMAL) for line in shown_log] + [("─" * max(0, w - 1), curses.A_DIM)] + panel
        rows += [(bar, curses.A_NORMAL) for bar in bars]
        for y, (text, attr) in enumerate(rows[-h:]):  # if the screen is short, the progress stays visible
            try:
                scr.addnstr(y, 0, text, max(0, w - 1), attr)
            except curses.error:
                pass
        scr.refresh()

    def _redraw(self):
        if self.drawn:
            sys.stderr.write(f"\x1b[{self.drawn}A\x1b[J")
        lines = [fit(line) for line in self._lines()]  # a wrapped line would throw off the count above
        for line in lines:
            sys.stderr.write(line + "\n")
        self.drawn = len(lines)
        sys.stderr.flush()

    def _lines(self):
        """The bottom of the screen: open questions, then the overall bar and one bar per target.

        Questions sit above the bars so the progress is always last. The block is kept shorter than the
        terminal, because a taller block cannot be redrawn in place and scrolls the screen.
        """
        bars = ([self._overall()] if self.targets else []) + [self._render(name, st) for name, st in self.targets.items()]
        ignored = [f"⏭️  ignored so far: {', '.join(self.ignored)}"] if self.ignored else []
        if not self.questions:
            return ignored + bars
        room = max(0, shutil.get_terminal_size((120, 24)).lines - len(bars) - len(ignored) - 3)
        shown = self.questions[:room]
        head = ["❓ Type i<n> and Enter to ignore that directory and everything under it:"]
        head += [self._question(q) for q in shown]
        if len(shown) < len(self.questions):
            head.append(f"   … and {len(self.questions) - len(shown)} more")
        return head + ignored + bars

    @staticmethod
    def _question(q):
        """One question on one line. A long path loses its front, so the directory's own name stays visible."""
        n, path, suffix = q
        prefix = f"❓ i{n}  ignore "
        room = terminal_width() - len(prefix) - len(suffix)
        if len(path) > room:
            path = "…" + path[-(room - 1):] if room > 1 else "…"
        return prefix + path + suffix

    def _overall(self):
        done = sum(st["done"] for st in self.targets.values())
        total = sum(max(st["total"] or 0, st["done"]) for st in self.targets.values() if st["total"] is not None)
        counting = [n for n, st in self.targets.items()
                    if st["total"] is None and st["phase"] not in ("stopped", "failed")]
        label = f"{'📊 all targets':<18}"
        if total and not counting:
            frac = done / total
            cells = int(30 * frac)
            return (f"{label} {'overall':<9} [{'█' * cells}{'░' * (30 - cells)}] {100 * frac:3.0f}%  "
                    f"{done:,}/{total:,} files")
        return f"{label} {'counting':<9} {done:,} files counted so far across {len(self.targets)} target(s)"

    def _log_milestone(self, name, st):
        total = st["total"] or 0
        pct = min(100, int(100 * st["done"] / total)) if total else -1
        milestone = pct // 10 if pct >= 0 else -1
        if st["phase"] != st.get("last_phase") or milestone > st["milestone"]:
            st["milestone"], st["last_phase"] = milestone, st["phase"]
            sys.stderr.write(f"{time.strftime('%H:%M:%S')} {self._render(name, st)}\n")
            sys.stderr.flush()

    @staticmethod
    def _render(name, st):
        # Same icons as the log lines: a node is 🖥️ [node/x]; a local scan has its own.
        label = f"💻 {name}" if name == "local" else f"🖥️  node/{name}"
        label = f"{label:<18}"
        done, total, phase = st["done"], st["total"], st["phase"]
        if total is not None and done > total:
            total = done  # the count was an underestimate; grow the bar rather than overflow it
        if total:
            frac = done / total
            cells = int(30 * frac)
            bar = "█" * cells + "░" * (30 - cells)
            elapsed = time.monotonic() - st["started"]
            rate = done / elapsed if elapsed > 0 and done else 0
            eta = f"ETA {int((total - done) / rate) // 60}m{int((total - done) / rate) % 60:02d}s" \
                if rate and total > done else ""
            return f"{label:<16} {phase:<9} [{bar}] {100 * frac:3.0f}%  {done:,}/{total:,} files  {eta}"
        return f"{label:<16} {phase:<9} {done:,} files counted so far"


BOARD = Board()
PROGRESS = "PROGRESS "  # prefix of a progress line a scan process emits; the controller turns it into a bar
PROGRESS_SINK = None  # where this process reports progress: a callable(fields), set by main per mode


def report_progress(**fields):
    if PROGRESS_SINK:
        PROGRESS_SINK(fields)


def stderr_sink(fields):
    """In a debug pod or a remote scan, the controller reads these lines from stderr and draws the bar."""
    sys.stderr.write(PROGRESS + json.dumps(fields) + "\n")
    sys.stderr.flush()


def board_sink(fields):
    handle_progress("local", fields)


def label(target):
    return target if target == "local" else f"node/{target}"


def serialised(method):
    """Runs under the board's lock: relay threads and the keyboard reader both touch the questions."""
    def wrapper(self, *args, **kwargs):
        with BOARD.lock:
            return method(self, *args, **kwargs)
    return wrapper


class Ignorer:
    """Warns about roots that take too long, and carries out the operator's choice to ignore one.

    Ignoring a root never terminates the scan: it stops that root's process (wherever it is running),
    adds the root to IGNORED_ROOTS so no later pass reads it, and tells each debug pod through
    IGNORE_FILE. A process in uninterruptible sleep only stops once its read returns, so it may
    take a while to show as stopped.
    """

    def __init__(self):
        self.pending = {}  # question number -> {"target", "root", "phase", "files"}
        self.next_id = 1
        self.current = {}  # target -> {"root", "pid"} of the process running now
        self.handlers = {}  # target -> callable(root, pid) that acts on it; pods and local

    @serialised
    def track(self, target, fields):
        if "root" in fields:
            self.current[target] = {"root": fields["root"], "pid": fields.get("pid")}
            for n in [n for n, e in self.pending.items() if e["target"] == target and e["root"] != fields["root"]]:
                del self.pending[n]  # the target has moved on from the root it was asked about
        if fields.get("phase") in ("done", "stopped", "failed"):
            self.current.pop(target, None)
            for n in [n for n, e in self.pending.items() if e["target"] == target]:
                del self.pending[n]
        self._show()

    @serialised
    def sync(self, target, root, phase, paths):
        """Makes the open questions for this target's root match the directories the clock offers now."""
        paths = [p for p in paths if offerable(p)]
        mine = {e["path"]: m for m, e in self.pending.items() if e["target"] == target and e["root"] == root}
        for path, m in mine.items():
            if path not in paths:
                del self.pending[m]  # its directory has been finished
            else:
                self.pending[m]["phase"] = phase
        for p in paths:
            if p not in mine:
                self.pending[self.next_id] = {"target": target, "root": root, "path": p, "phase": phase}
                self.next_id += 1
        self._show()

    def _show(self):
        BOARD.ask([(n, e["path"], f" on {label(e['target'])} ({e['phase']})")
                   for n, e in sorted(self.pending.items())])

    @serialised
    def ignore(self, n):
        e = self.pending.get(n)
        if e is None:
            BOARD.say(f"no open question i{n}")
            BOARD.status = f"no open question i{n}"
            return
        path = e["path"]
        IGNORED_ROOTS.add(path)
        if not any(r["root"] == path and r.get("target") == label(e["target"]) for r in IGNORED_REPORT):
            IGNORED_REPORT.append({"root": path, "files": 0, "how": f"ignored during its {e['phase']}",
                                   "target": label(e["target"])})
        if path not in BOARD.ignored:
            BOARD.ignored.append(path)
        for m in [m for m, f in self.pending.items() if covered_by(f["path"], path)]:
            del self.pending[m]
        touched = []
        for target, handler in list(self.handlers.items()):
            cur = self.current.get(target)
            pid = cur["pid"] if cur and cur["root"] and path.startswith(cur["root"]) else None
            handler(path, pid)
            if pid:
                touched.append(label(target))
        BOARD.say(f"⏭️  ignoring {path} and everything under it for the rest of this scan"
                  + (f"; stopped the walk on {', '.join(touched)}" if touched else ""))
        BOARD.status = f"ignored {path}" + (f"; stopped the walk on {', '.join(touched)}" if touched else "")
        self._show()


IGNORER = Ignorer()


def stop_local_root(root, pid):
    # Nothing is signalled or restarted: the walks re-read the list and skip the directory from here on.
    publish_ignores(LOCAL_IGNORE_FILE)


def handle_progress(target, fields):
    """One progress line from a scan (a pod, a remote, or this process): update its bar, and raise a
    warning or act on it if it carries one."""
    offers = fields.pop("offers", None)
    BOARD.set(target, **fields)
    IGNORER.track(target, fields)
    if offers is not None:
        IGNORER.sync(target, fields.get("root"), offers["phase"], offers["paths"])


def note(message):
    """A line for the operator, timestamped, kept clear of the progress bars."""
    BOARD.say(message)


def killed(what, why):
    """Every process this scan kills is logged with the reason, so an unexplained exit can be traced."""
    note(f"stopping {what}: {why}")


def drop_cache(f):
    """Tell the kernel a file will not be read again, so its pages do not fill the pod's memory limit."""
    try:
        os.posix_fadvise(f.fileno(), 0, 0, os.POSIX_FADV_DONTNEED)
    except (AttributeError, OSError):
        pass


SLOW_ROOT_SECONDS = 60  # a root still being counted or scanned after this long gets a warning
IGNORE_FILE = "/dev/shm/wraithwatch-ignore"  # in a debug pod: roots the operator has ignored, one per line
IGNORED_ROOTS = set()  # roots to skip for the rest of the scan (display paths, e.g. /var/lib/kubelet)
IGNORED_REPORT = []  # every root that was ignored, with what had been read of it
COUNT_STATE = {"n": 0}  # running count of a counting child, reported if it is ignored
CHILD_STATE = {"records": []}  # records a scan child has found so far, reported if it is ignored


def display_root(root, prefix):
    """The root as the operator knows it: without the node-root prefix inside a debug pod."""
    if prefix and root.startswith(prefix):
        return root[len(prefix):] or "/"
    return root


LOCAL_IGNORE_FILE = os.path.expanduser(f"~/.cache/wraithwatch/ignore-{os.getpid()}")  # for this run's local walks
LIVE = {"file": None, "prefix": "", "paths": set(), "checked": 0.0}


def configure_child(prefix, ignore_file):
    """In a scan process: the file of ignored directories to re-read as it walks, and the prefix its paths lack."""
    LIVE.update(file=ignore_file, prefix=prefix)


def live_ignored():
    """Directories the operator has ignored, re-read from the control file at most once a second. A walk
    checks this at every directory, so an ignore takes effect without restarting the walk."""
    now = time.monotonic()
    if LIVE["file"] and now - LIVE["checked"] >= 1.0:
        LIVE["checked"] = now
        try:
            with open(LIVE["file"]) as f:
                LIVE["paths"] = {LIVE["prefix"] + line.strip() for line in f if line.strip()}
        except OSError:
            pass
    return LIVE["paths"]


def live_covers(path):
    return any(covered_by(path, i) for i in live_ignored())


def publish_ignores(path):
    """Writes the ignored directories where this run's walks read them. Atomic, and only this user can read it."""
    if not path:
        return
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("".join(p + "\n" for p in sorted(IGNORED_ROOTS)))
    os.replace(tmp, path)


def refresh_ignored():
    """In a debug pod, pick up roots the operator has ignored since the scan started."""
    if PROGRESS_SINK is stderr_sink:
        try:
            with open(IGNORE_FILE) as f:
                IGNORED_ROOTS.update(line.strip() for line in f if line.strip())
        except OSError:
            pass


def covered_by(path, ancestor):
    return path == ancestor or path.startswith(ancestor.rstrip("/") + "/")


def ignored_covers(path):
    return any(covered_by(path, i) for i in IGNORED_ROOTS)


def is_volume_root(path):
    """A pod's volume mount or its pod directory: where a kubelet volume starts, and not worth asking about."""
    return os.path.basename(path) == "globalmount" or re.fullmatch(r"/var/lib/kubelet/pods/[^/]+", path) is not None


def offerable(path):
    return not ignored_covers(path) and not is_volume_root(path)


class DirClock:
    """Charges the time a root's walk spends to each directory and to its parents, up to the root.

    A directory is charged from the moment it is listed until the next directory is listed, which is
    the time spent reading its files and entering its subdirectories. enter() and poll() return the
    directories the operator can ignore now, as a list:

    - a directory that has reached SLOW_ROOT_SECONDS is offered, unless a deeper offered directory
      sits under it, since the deepest one is the one to decide about;
    - an offered directory stays offered until the walk leaves it, so it does not vanish while the
      deeper directory under it is still going;
    - when the walk leaves a directory, it is no longer offered; a shallower directory that has already
      reached the limit is then offered in its place.
    """

    def __init__(self, root):
        self.root = root.rstrip("/") or "/"
        self.cur = None
        self.since = time.monotonic()
        self.spent = {}
        self.offered = []
        self.walk_entered = set()  # directories this walk has entered

    def restart(self):
        """The root is walked again from the top (after an ignore). Offers carry over; no directory is
        finished just because the new walk starts elsewhere."""
        self.cur = None
        self.walk_entered = set()
        self.since = time.monotonic()

    def _chain(self, d):
        while True:
            yield d
            if d == self.root or os.path.dirname(d) == d:
                return
            d = os.path.dirname(d)

    def _candidates(self, chain):
        """Directories an offer may name. Under a volume, only what lies below it: the directories above a
        volume belong to the storage driver, and the operator is not asked about them."""
        volumes = [p for p in chain if is_volume_root(p)]
        if not volumes:
            return list(chain)
        floor = max(volumes, key=len)
        return [p for p in chain if covered_by(p, floor) and p != floor]

    def _offers(self, extra):
        if self.cur is None:
            return list(self.offered)
        chain = list(self._chain(self.cur))
        # Finished: this walk went into the directory and has since left it. An offer the walk has not
        # reached yet stays, as does one from an earlier walk.
        self.offered = [p for p in self.offered if not ignored_covers(p) and (p in chain or p not in self.walk_entered)]
        for p in sorted(self._candidates(chain), key=len, reverse=True):  # deepest first
            if self.spent.get(p, 0) + extra < SLOW_ROOT_SECONDS or p in self.offered or not offerable(p):
                continue
            if any(o.startswith(p + "/") for o in self.offered):
                continue  # a deeper directory under it is already the one to decide about
            self.offered.append(p)
        return list(self.offered)

    def enter(self, d):
        now = time.monotonic()
        if self.cur is not None:
            for p in self._chain(self.cur):
                self.spent[p] = self.spent.get(p, 0) + (now - self.since)
        self.cur, self.since = d, now
        self.walk_entered.update(self._chain(d))
        return self._offers(0)

    def poll(self):
        return self._offers(time.monotonic() - self.since)


def watch(offers, phase, progress, cur):
    """Tracks the process on its current root, and sends the directories offered for ignoring when they change."""
    cur["pid"] = progress["pid"]
    if offers != cur.get("offers"):
        cur["offers"] = offers
        report_progress(offers={"paths": offers, "phase": phase}, root=cur["root"], pid=progress["pid"])


def report_ignored(path, files, how):
    """Record an ignored path once. The first call sets how; later calls only raise the file count."""
    for e in IGNORED_REPORT:
        if e["root"] == path:
            e["files"] = max(e["files"], files)
            return False
    IGNORED_REPORT.append({"root": path, "files": files, "how": how})
    return True


def report_skipped(root):
    """Record each ignored directory under root, so the report lists directories a later pass skips."""
    under = root.rstrip("/") + "/"
    for p in sorted(IGNORED_ROOTS):
        if p.startswith(under):
            report_ignored(p, 0, "not scanned")


def supervise(cmd, data, idle=None, overall=None, on_line=None, on_file=None, on_count=None, on_dir=None,
              on_tick=None):
    """Run a process and follow its stderr line by line.

    Returns (outcome, returncode, stdout, stderr_tail, progress). outcome is "ok", "idle" (no output for
    `idle` seconds) or "overall" (still running after `overall` seconds). "F <path>" lines are per-file
    progress from a scan process: each goes to on_file(path) and is counted in progress["files"];
    "C <dir>" lines are heartbeats from the counting walk; every other line goes to on_line.

    A process that goes idle or overruns is killed and abandoned without waiting: one blocked in an
    uninterruptible read cannot be reaped. Its reader threads stay until this process exits.
    """
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out, tail = bytearray(), bytearray()
    start = time.monotonic()
    progress = {"files": 0, "last_file": None, "last_dir": None, "last": None, "beat": start, "pid": proc.pid,
                "started": start}

    def handle(raw):
        line = raw.decode(errors="replace").rstrip("\r")
        progress["beat"] = time.monotonic()
        if line.startswith("F "):
            progress["files"] += 1
            progress["last_file"] = line[2:]
            if on_file:
                on_file(line[2:])
            return
        if line.startswith("C "):
            progress["last_dir"] = line[2:]
            if on_dir:
                on_dir(line[2:], progress)
            return
        if line.startswith("K "):
            if on_count:
                on_count(int(line[2:]))
            return
        progress["last"] = line
        tail.extend(raw + b"\n")
        del tail[:-STDERR_TAIL_BYTES]
        if on_line:
            on_line(line)

    def pump_out():
        for chunk in iter(lambda: proc.stdout.read(65536), b""):
            out.extend(chunk)

    def pump_err():
        # read1 returns as soon as any bytes arrive; read(n) would wait for n bytes and miss progress
        buf = b""
        for chunk in iter(lambda: proc.stderr.read1(4096), b""):
            buf += chunk
            *lines, buf = buf.split(b"\n")
            for raw in lines:
                handle(raw)
        if buf:
            handle(buf)

    def feed():
        try:
            proc.stdin.write(data)
            proc.stdin.close()
        except OSError:
            pass

    threads = [threading.Thread(target=f, daemon=True) for f in (pump_out, pump_err, feed)]
    for t in threads:
        t.start()
    while True:
        try:
            rc = proc.wait(timeout=1)
            break
        except subprocess.TimeoutExpired:
            now = time.monotonic()
            outcome = None
            if on_tick:
                on_tick(progress)
            if idle is not None and now - progress["beat"] > idle:
                outcome = "idle"
            elif overall is not None and now - start > overall:
                outcome = "overall"
            if outcome:
                killed(f"{cmd[0]} (pid {proc.pid})", f"{outcome} limit reached, no progress for {idle}s"
                       if outcome == "idle" else f"ran past the {overall}s limit")
                proc.kill()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
                for t in threads:
                    t.join(timeout=2)
                return outcome, None, bytes(out), bytes(tail), progress
    for t in threads:
        t.join(timeout=10)
    return "ok", rc, bytes(out), bytes(tail), progress


STATE_PATH = os.path.expanduser("~/.cache/wraithwatch/scan-state.json")
CHECKPOINT_PREFIX = "CHECKPOINT "  # a pod's line carrying one finished root's results to the controller
CHECKPOINT = None  # the controller's ScanState, set by main; None inside a pod
POD_LOCATIONS = None  # inside a pod: converts record locations the way its final payload does


class ScanState:
    """Progress kept so a run can continue after it stops: finished roots, finished nodes, and the ignores.

    Written after every root and every node, to a file only this user can read. It holds the same
    findings as the report. A run that finishes removes it.
    """

    def __init__(self, path, signature, data=None):
        self.path = path
        self.data = data or {"signature": signature, "roots": {}, "nodes": {}, "ignored": [], "ignored_report": []}
        self.lock = threading.RLock()

    @staticmethod
    def read(path):
        try:
            with open(path) as f:
                return json.load(f)
        except FileNotFoundError:
            return None
        except ValueError as exc:
            raise RuntimeError(f"the saved progress in {path} is unreadable ({exc}); remove it to start over")

    def add_root(self, scope, root, piece):
        with self.lock:
            self.data["roots"].setdefault(scope, {})[root] = piece
            self.save()

    def roots(self, scope):
        return self.data["roots"].get(scope, {})

    def node(self, name):
        return self.data["nodes"].get(name, {})

    def set_node(self, name, **fields):
        with self.lock:
            self.data["nodes"].setdefault(name, {}).update(fields)
            self.save()

    def save(self):
        self.data["ignored"] = sorted(IGNORED_ROOTS)
        self.data["ignored_report"] = list(IGNORED_REPORT)
        os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
        tmp = self.path + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(self.data, f)
        os.replace(tmp, self.path)

    def finish(self):
        with contextlib.suppress(FileNotFoundError):
            os.remove(self.path)


def checkpoint_root(disp, piece):
    """Keeps one finished root's results, so a run that stops later does not lose them. Inside a pod the
    results go to the controller on stderr, and the controller saves them."""
    if PROGRESS_SINK is stderr_sink:
        if POD_LOCATIONS:
            piece = dict(piece, records=POD_LOCATIONS(piece["records"]))
        sys.stderr.write(CHECKPOINT_PREFIX + json.dumps({"root": disp, "piece": piece}) + "\n")
        sys.stderr.flush()
    elif CHECKPOINT is not None:
        CHECKPOINT.add_root("local", disp, piece)


def pod_locations(records, index, node_root):
    out = []
    for r in records:
        if r["location"].startswith(node_root + "/"):
            r = dict(r, location=storage_location(index, node_root, r["location"]))
        out.append(r)
    return out


def scan_local(roots, passwords, skip=True, skip_paths=frozenset(), prefix="", mountinfo="/proc/self/mountinfo",
               isolate=True, resumed=None, ignore_file=None):
    """Scan roots and return (records, gaps).

    With isolate, each root is scanned by its own process, so a hung filesystem is detected by its
    silence and raises ScanStalled instead of blocking the scan. resumed maps roots that finished in an
    earlier run to their saved results; those are not scanned again.
    """
    resumed = resumed or {}
    ignore_file = ignore_file or LOCAL_IGNORE_FILE  # walks re-read it; see live_ignored()
    records, gaps = [], []
    if not isolate:
        seen, pseudo = set(), pseudo_mountpoints(prefix, mountinfo)
        CHILD_STATE["records"] = records
        for root in dict.fromkeys(roots):
            if not os.path.isdir(root):
                gaps.append(f"{root}: no such directory")
            elif not is_pseudo(root):
                records += scan_entries(iter_local(root, skip, seen, skip_paths, pseudo), "", passwords)
        return records, gaps

    script = globals().get("SCRIPT_SOURCE")
    if script is None:
        with open(__file__, "rb") as f:
            script = f.read()
    check = "all" if SCAN_CERTS and SCAN_RUNTIMES else "certs" if SCAN_CERTS else "runtimes"
    keys = set()

    def take(found):
        for r in found:
            # Overlapping roots yield the same record twice; a 20-byte digest keeps the set small.
            key = hashlib.sha1(json.dumps(r, sort_keys=True).encode()).digest()
            if key not in keys:
                keys.add(key)
                records.append(r)

    def child_argv(root, *extra):
        disp = display_root(root, prefix)
        under = disp.rstrip("/") + "/"
        skips = set(skip_paths) | {prefix + p for p in IGNORED_ROOTS if p.startswith(under)}
        argv = ["--scan-root", root, "--check", check, "--prefix", prefix, "--mountinfo", mountinfo,
                "--ignore-file", ignore_file, *extra]
        if not skip:
            argv.append("--no-skip")
        for p in sorted(skips):
            argv += ["--skip-path", p]
        return [sys.executable, "-c", BOOTSTRAP] + argv

    # Pass 1: count the files, so progress can be a fraction of the whole. Metadata only.
    # A directory the operator ignores mid-count restarts this root's count without it.
    publish_ignores(ignore_file)  # the ignores of an earlier run, if resumed, are in effect from the start
    total = 0
    counts = {}
    cur = {"root": None, "pid": None}
    report_progress(phase="counting", done=0, total=None)
    for root in dict.fromkeys(roots):
        disp = display_root(root, prefix)
        if disp in resumed:
            total += resumed[disp].get("count", 0)
            continue
        base = total
        clock = DirClock(disp)
        while True:
            refresh_ignored()
            if disp in IGNORED_ROOTS:
                break  # ignored before or during its count; the scan pass records it
            report_skipped(disp)
            cur.update(root=disp, pid=None, offers=None)
            clock.restart()

            def on_count(n, base=base):
                report_progress(phase="counting", done=base + n, total=None, root=cur["root"], pid=cur["pid"])

            def on_dir(d, progress):
                watch(clock.enter(display_root(d, prefix)), "counting", progress, cur)

            def on_tick(progress):
                watch(clock.poll(), "counting", progress, cur)

            outcome, rc, out, tail, progress = supervise(child_argv(root, "--count-only"),
                                                         stdin_payload(script, passwords), idle=STALL_TIMEOUT,
                                                         on_count=on_count, on_dir=on_dir, on_tick=on_tick)
            if outcome == "idle":
                raise ScanStalled(f"{root}: no progress for {STALL_TIMEOUT}s while counting files; stuck at "
                                  f"{progress['last_dir']} (a stale NFS/CIFS mount is the usual cause)",
                                  partial=records)
            if rc == -signal.SIGUSR1:
                continue  # ignored before its process had installed the handler
            if rc != 0:
                raise ScanFailed(f"{root}: counting files failed: {progress['last'] or f'exit {rc}'}",
                                 partial=records)
            result = json.loads(out)
            if not result.get("ignored"):
                total = base + result["count"]
                counts[disp] = result["count"]
                break
        report_progress(phase="counting", done=total, total=None)

    # Pass 2: scan. Each file read is one step of progress against the whole count.
    done, last_sent = [0], [0.0]

    def on_file(path):
        done[0] += 1
        now = time.monotonic()
        if now - last_sent[0] >= 0.5:
            last_sent[0] = now
            report_progress(phase="scanning", done=done[0], total=total, root=cur["root"], pid=cur["pid"])

    report_progress(phase="scanning", done=0, total=total)
    for root in dict.fromkeys(roots):
        disp = display_root(root, prefix)
        if disp in resumed:
            piece = resumed[disp]
            take(piece.get("records", []))
            gaps += piece.get("gaps", [])
            WARNINGS.extend(w for w in piece.get("warnings", []) if w not in WARNINGS)
            TOTALS["files"] += piece.get("stats", {}).get("files", 0)
            TOTALS["bytes"] += piece.get("stats", {}).get("bytes", 0)
            done[0] += piece.get("stats", {}).get("files", 0)
            note(f"{disp}: finished in an earlier run; its saved results are used")
            continue
        started = time.monotonic()
        clock = DirClock(disp)
        while True:
            refresh_ignored()
            if disp in IGNORED_ROOTS:
                if report_ignored(disp, 0, "ignored, not scanned"):
                    note(f"{disp}: ignored, not scanned")
                break
            report_skipped(disp)
            cur.update(root=disp, pid=None, offers=None)
            clock.restart()
            before = set(IGNORED_ROOTS)

            def on_dir(d, progress):
                watch(clock.enter(display_root(d, prefix)), "scanning", progress, cur)

            def on_tick(progress):
                watch(clock.poll(), "scanning", progress, cur)

            outcome, rc, out, tail, progress = supervise(child_argv(root), stdin_payload(script, passwords),
                                                         idle=STALL_TIMEOUT, on_file=on_file, on_dir=on_dir,
                                                         on_tick=on_tick)
            if outcome == "idle":
                raise ScanStalled(f"{root}: no progress for {STALL_TIMEOUT}s after {progress['files']} files; "
                                  f"stuck at {progress['last_file']} (a stale NFS/CIFS mount is the usual cause)",
                                  partial=records)
            if rc == -signal.SIGUSR1:
                continue  # ignored before its process had installed the handler
            if rc != 0:
                detail = progress["last"] or f"exit {rc}"
                raise ScanFailed(f"{root}: scan process failed: {detail}", partial=records)
            try:
                payload = json.loads(out)
            except ValueError as exc:
                raise ScanFailed(f"{root}: scan process returned unreadable results: {exc}", partial=records)
            stats = payload["stats"]
            TOTALS["files"] += stats["files"]
            TOTALS["bytes"] += stats["bytes"]
            gaps += payload["gaps"]
            WARNINGS.extend(w for w in payload["warnings"] if w not in WARNINGS)
            for r in payload["records"]:
                # Overlapping roots yield the same record twice; a 20-byte digest keeps the set small.
                key = hashlib.sha1(json.dumps(r, sort_keys=True).encode()).digest()
                if key not in keys:
                    keys.add(key)
                    records.append(r)
            if payload.get("ignored"):
                for p in sorted(IGNORED_ROOTS - before):
                    report_ignored(p, stats["files"], "ignored during its scan")
                    note(f"{p}: ignored after {stats['files']} files; what was read is kept")
                continue  # scan again without the ignored directories (or stop, if the root itself was ignored)
            checkpoint_root(disp, {"records": payload["records"], "gaps": payload["gaps"],
                                   "warnings": payload["warnings"], "stats": stats,
                                   "count": counts.get(disp, 0)})
            note(f"{root}: done, {stats['files']} files, {stats['bytes'] / 2**20:.1f} MiB, "
                 f"{time.monotonic() - started:.0f}s")
            break
    report_progress(phase="done", done=done[0], total=max(total, done[0]))
    return records, gaps


def scan_runtime(runtime, passwords, workers):
    out = run([runtime, "ps", "--format", "{{.ID}} {{.Names}}"])
    if out is None:
        raise RuntimeError(f"`{runtime} ps` failed")
    jobs = []
    for line in out.decode().splitlines():
        cid, _, name = line.strip().partition(" ")
        if cid:
            jobs.append(([runtime, "export", cid], f"{runtime}:{name or cid}"))
    return run_jobs(jobs, passwords, workers)


def toml_root(text):
    """Top-level `root = "..."` in a TOML file (keys before the first table)."""
    head = text.split("\n[", 1)[0]
    m = re.search(r'^\s*root\s*=\s*"([^"]+)"', head, re.M)
    return m.group(1) if m else None


def list_dir(path):
    try:
        return os.listdir(path)
    except OSError:
        return []


def unescape_mount(text):
    return re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), text)


def read_mounts(path=HOST_MOUNTINFO):
    """A mount table. In the debug pod, PID 1 is the host init (hostPID), so its mountinfo is the host's."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError as exc:
        raise RuntimeError(f"cannot read {path}: {exc.strerror}") from exc
    mounts = []
    for line in lines:
        fields = line.split(" ")
        if "-" not in fields[6:]:
            continue
        sep = fields.index("-", 6)
        if len(fields) < sep + 3:
            continue
        m = {"devid": fields[2], "root": unescape_mount(fields[3]), "mountpoint": unescape_mount(fields[4]),
             "fstype": fields[sep + 1], "source": unescape_mount(fields[sep + 2])}
        m["share"], m["export"] = network_share(m)
        m["kind"] = mount_kind(m)
        if m["kind"] == "network" and not m["share"]:
            m["share"], m["export"] = m["source"] + ":", "/"
        mounts.append(m)
    return mounts


def network_share(m):
    """(prefix, export) for a network mount, e.g. ("10.0.0.5:", "/export"); (None, None) otherwise."""
    src = m["source"]
    if src.startswith("//"):
        host, _, share = src[2:].partition("/")
        return f"//{host}", "/" + share
    host, sep, export = src.partition(":/")
    if sep and not src.startswith("/"):
        return f"{host}:", "/" + export
    return None, None


def block_is_remote(sysdir):
    """True for block devices served over the network (iSCSI, RBD, NBD, NVMe-oF), following device-mapper slaves."""
    real = os.path.realpath(sysdir)
    if os.path.basename(real).startswith(("rbd", "nbd", "drbd")) or "/session" in real or "/nvme-fabrics/" in real:
        return True
    return any(block_is_remote(os.path.join("/sys/class/block", s)) for s in list_dir(os.path.join(real, "slaves")))


def mount_kind(m):
    """'network' (shared by many nodes), 'remote' (network block device), or 'local'.

    Decided from the mount source and the backing block device; the filesystem type is only
    consulted when neither says anything.
    """
    if m["share"]:
        return "network"
    sysdir = os.path.join("/sys/dev/block", m["devid"])
    if os.path.exists(sysdir):
        return "remote" if block_is_remote(sysdir) else "local"
    return "network" if m["fstype"] in NETWORK_FS else "local"


def backend_path(export, root):
    """Path of a mount's contents within the network filesystem. `root` may or may not repeat the export."""
    base = export.rstrip("/")
    if root == export or root.startswith(base + "/"):
        full = root
    else:
        full = base + root
    return posixpath.normpath(full)


def pv_name(mountpoint):
    """PersistentVolume name from a kubelet mount path, for labelling local storage."""
    parts = mountpoint.strip("/").split("/")
    for i in range(len(parts) - 4):
        if parts[i:i + 4] == ["plugins", "kubernetes.io", "csi", "pv"]:
            return parts[i + 4]
    for i in range(len(parts) - 4):
        if parts[i] == "pods" and parts[i + 2] == "volumes" and parts[i + 3] in PV_PLUGIN_DIRS:
            return parts[i + 4]
    return None


def mount_index(mounts):
    """Mounts ordered so the most specific (longest mountpoint, latest stacked) comes first."""
    return sorted(reversed(mounts), key=lambda m: -len(m["mountpoint"]))


def find_mount(index, host_path):
    for m in index:
        mp = m["mountpoint"]
        if host_path == mp or host_path.startswith(mp.rstrip("/") + "/"):
            return m
    return None


REDACT_SALT = ""  # per-scan salt, so hashes are stable within one run but not across runs
REVEAL_NAMES = False
SCAN_CERTS = True  # --check certs/all; when off, certificate parsing (and its I/O) is skipped entirely
SCAN_RUNTIMES = True  # --check runtimes/all


def redact(kind, value):
    if REVEAL_NAMES:
        return value
    digest = hashlib.sha256(f"{REDACT_SALT}\0{kind}\0{value}".encode()).hexdigest()[:8]
    return f"<{kind}:{digest}>"


def redact_host_path(path):
    """Hide Secret/volume names and PV names in a kubelet host path; pod UIDs and the rest stay."""
    parts = path.split("/")
    for i in range(len(parts) - 1):
        if parts[i].startswith("kubernetes.io~"):
            kind = "secret" if parts[i] == "kubernetes.io~secret" else "pv" if parts[i] in PV_PLUGIN_DIRS else "volume"
            parts[i + 1] = redact(kind, parts[i + 1])
        elif parts[i] == "pv" and i and parts[i - 1] == "csi":
            parts[i + 1] = redact("pv", parts[i + 1])
    return "/".join(parts)


def redact_backend(share, export, path):
    """Network location: server and export are hidden, the path below the export is kept."""
    base = export.rstrip("/")
    return f"{redact('net', share)}{redact('export', base)}{path[len(base):]}"


def storage_location(index, node_root, path):
    """Report location for a file: the backend path on network storage, else the host path (with PV name)."""
    host = path[len(node_root):]
    m = find_mount(index, host)
    if m is None:
        return redact_host_path(path)
    if m["kind"] == "network":
        rel = host[len(m["mountpoint"].rstrip("/")):]
        full = posixpath.normpath(backend_path(m["export"], m["root"]) + rel)
        return redact_backend(m["share"], m["export"], full)
    label = pv_name(m["mountpoint"]) if m["mountpoint"] != "/" else None
    shown = redact_host_path(path)
    return f"{shown} (pv {redact('pv', label)})" if label else shown


def network_entries(mounts, roots, node_root):
    """Network mounts under the scanned roots, for the controller to plan which node scans each."""
    entries = []
    for m in mounts:
        local = os.path.join(node_root, m["mountpoint"].lstrip("/"))
        if m["kind"] == "network" and any(local == r or local.startswith(r + "/") for r in roots):
            entries.append({"mount": m["mountpoint"], "share": m["share"], "export": m["export"],
                            "path": backend_path(m["export"], m["root"])})
    return entries


def probe_node(node_root):
    """Find where this node keeps container and kubelet data by reading its config.

    Returns (existing directories on the local filesystem, human-readable findings).
    """
    def read(rel):
        try:
            with open(os.path.join(node_root, rel), encoding="utf-8", errors="replace") as f:
                return f.read()
        except OSError:
            return None

    probes = []
    text = read("etc/containerd/config.toml")
    probes.append(("containerd", toml_root(text) if text else None,
                   "etc/containerd/config.toml" if text else None, "/var/lib/containerd"))

    text = read("etc/containers/storage.conf")
    m = re.search(r'^\s*graphroot\s*=\s*"([^"]+)"', text, re.M) if text else None
    probes.append(("containers/storage (CRI-O)", m.group(1) if m else None,
                   "etc/containers/storage.conf" if text else None, "/var/lib/containers/storage"))

    text = read("etc/docker/daemon.json")
    try:
        docker_root = json.loads(text).get("data-root") if text else None
    except (ValueError, AttributeError):
        docker_root = None
    probes.append(("docker", docker_root,
                   "etc/docker/daemon.json" if text else None, "/var/lib/docker"))

    text = read("var/lib/kubelet/config.yaml")
    m = re.search(r'^rootDirectory:\s*"?([^"\s]+)"?\s*$', text, re.M) if text else None
    probes.append(("kubelet root", m.group(1) if m else None,
                   "var/lib/kubelet/config.yaml" if text else None, "/var/lib/kubelet"))

    roots, info = [], []
    for name, configured, source, default in probes:
        path = configured or default
        if configured:
            origin = f"set in /{source}"
        elif source:
            origin = f"no root set in /{source}, default used"
        else:
            origin = "no config file, default used"
        local = os.path.join(node_root, path.lstrip("/"))
        if os.path.isdir(local):
            roots.append(local)
            info.append(f"{name}: {path} ({origin})")
        else:
            info.append(f"{name}: {path} not present ({origin})")
    return roots, info


def node_payload(args, passwords):
    global POD_LOCATIONS
    roots, info = probe_node(args.node_root)
    info.insert(0, f"node reports container runtime: {args.runtime_hint or 'unknown'}")
    errors = []
    if not roots:
        errors.append(f"no container storage found under {args.node_root}")
    if SCAN_CERTS:
        if not shutil.which("openssl"):
            errors.append("openssl not found in the debug image: PKCS#7/PKCS#12 stores are checked by raw byte search only")
        if not shutil.which("keytool"):
            info.append("keytool not found in the debug image: JKS/JCEKS stores are checked by raw byte search only")
    mounts = read_mounts()
    index = mount_index(mounts)
    skip_paths = frozenset(os.path.join(args.node_root, m.lstrip("/")) for m in args.skip_mount)
    IGNORED_ROOTS.update(args.ignore_root)
    POD_LOCATIONS = lambda found: pod_locations(found, index, args.node_root)  # noqa: E731
    # A failure is reported in the payload, with what was found, rather than raised: the controller
    # needs to see the partial records and decide how to tear the pod down.
    failed, stalled, gaps = None, False, []
    try:
        records, gaps = scan_local(roots, passwords, skip=False, skip_paths=skip_paths,
                                   prefix=args.node_root, mountinfo=HOST_MOUNTINFO,
                                   resumed={d: {} for d in args.done_root}, ignore_file=IGNORE_FILE)
    except ScanFailed as exc:
        records, failed, stalled = exc.partial, str(exc), isinstance(exc, ScanStalled)
    records = pod_locations(records, index, args.node_root)
    return {"records": records, "errors": errors + WARNINGS, "info": info, "gaps": gaps,
            "failed": failed, "stalled": stalled, "stats": dict(TOTALS), "ignored": list(IGNORED_REPORT)}


def log(node, message):
    BOARD.say(f"🖥️  [node/{node}] {message}")


def last_line(text, fallback):
    lines = [line for line in text.strip().splitlines() if line.strip()]
    return lines[-1] if lines else fallback


def error_line(text, fallback):
    lines = [line for line in text.strip().splitlines()
             if line.strip() and not line.startswith("Warning:")]
    return lines[-1] if lines else fallback


def pod_state(pod):
    """Return ("ready", None), ("failed", reason), or ("waiting", reason) for a debug pod."""
    status = pod.get("status", {})
    phase = status.get("phase", "")
    if phase in ("Failed", "Succeeded"):
        return "failed", f"pod {phase.lower()}: {status.get('reason', '')} {status.get('message', '')}".strip()
    for cs in status.get("containerStatuses", []):
        state = cs.get("state", {})
        if "running" in state:
            return "ready", None
        if "terminated" in state:
            t = state["terminated"]
            return "failed", f"container exited ({t.get('reason', '')}, exit code {t.get('exitCode')})"
        waiting = state.get("waiting", {})
        reason = waiting.get("reason", "")
        if reason in STARTUP_FAILURE_REASONS:
            return "failed", f"{reason}: {waiting.get('message', '')}".rstrip(": ")
        if reason:
            return "waiting", reason
    for cond in status.get("conditions", []):
        if cond.get("type") == "PodScheduled" and cond.get("status") == "False":
            return "waiting", f"not scheduled ({cond.get('reason', '')}: {cond.get('message', '')})"
    return "waiting", phase or "Pending"


def last_event(base, namespace, pod):
    out = run(base + ["get", "events", "-n", namespace,
                      "--field-selector", f"involvedObject.name={pod}", "-o", "json"])
    items = json.loads(out).get("items", []) if out else []
    if not items:
        return ""
    items.sort(key=lambda e: e.get("lastTimestamp") or e.get("eventTime") or "")
    event = items[-1]
    return f"{event.get('reason', '')}: {event.get('message', '')}"


def startup_error(base, namespace, pod, detail):
    event = last_event(base, namespace, pod)
    suffix = f" [last event: {event}]" if event else ""
    return RuntimeError(f"debug pod {pod} failed to start: {detail}{suffix}")


def wait_for_pod(base, args, pod, node):
    deadline = time.monotonic() + STARTUP_TIMEOUT
    last = None
    while True:
        out = run(base + ["get", "pod", pod, "-n", args.debug_namespace, "-o", "json"])
        if out is not None:
            obj = json.loads(out)
            state, detail = pod_state(obj)
            if state == "ready":
                return obj
            if state == "failed":
                raise startup_error(base, args.debug_namespace, pod, detail)
            if detail != last:
                log(node, f"debug pod {pod} waiting: {detail}")
                last = detail
        if time.monotonic() > deadline:
            raise startup_error(base, args.debug_namespace, pod,
                                f"not running after {STARTUP_TIMEOUT}s (last state: {last})")
        time.sleep(3)


def pod_post_mortem(base, args, pod):
    """What the cluster recorded about a pod: container exit reasons and its events. Read before deletion,
    since deleting the pod removes this record."""
    ns = args.debug_namespace
    out = run(base + ["get", "pod", pod, "-n", ns, "-o", "json"], timeout=30)
    if out is None:
        return "could not read pod state"
    parts = []
    try:
        pod_obj = json.loads(out)
    except ValueError:
        return "pod state unreadable"
    for cs in pod_obj.get("status", {}).get("containerStatuses", []) or []:
        for key in ("state", "lastState"):
            st = cs.get(key) or {}
            if "terminated" in st:
                t = st["terminated"]
                parts.append(f"{cs.get('name')} {key}: terminated reason={t.get('reason')} "
                             f"exit={t.get('exitCode')} finished={t.get('finishedAt')}")
            elif "running" in st:
                parts.append(f"{cs.get('name')} {key}: running since {st['running'].get('startedAt')}")
            elif "waiting" in st:
                parts.append(f"{cs.get('name')} {key}: waiting ({st['waiting'].get('reason')})")
    ev = run(base + ["get", "events", "-n", ns, "--field-selector", f"involvedObject.name={pod}", "-o", "json"],
             timeout=30)
    if ev is not None:
        try:
            items = json.loads(ev).get("items", [])
        except ValueError:
            items = []
        for e in items[-5:]:
            parts.append(f"event {e.get('reason')}: {e.get('message', '')}")
    return "; ".join(parts) or "no state recorded"


def delete_pod(base, args, pod, node, force=False, why=""):
    # Force deletion removes the API object while its container may still be running on the node,
    # invisibly, until a stuck read returns. So it happens only when the operator asks for it.
    extra = ["--grace-period=0", "--force"] if force else []
    rc, _, err = run_capture(base + ["delete", "pod", pod, "-n", args.debug_namespace,
                                     "--wait=false", "--ignore-not-found"] + extra, timeout=60)
    if rc != 0:
        log(node, f"WARNING: could not delete debug pod {pod}: "
                  f"{last_line(err.decode(errors='replace'), 'unknown error')}")
    else:
        log(node, f"debug pod {pod} deleted" + (" (forced)" if force else "") + (f": {why}" if why else ""))


class PodsExist(RuntimeError):
    pass


def list_managed_pods(base, namespace):
    out = run(base + ["get", "pods", "-n", namespace, "-l", f"{MANAGED_LABEL}=true", "-o", "json"])
    if out is None:
        raise RuntimeError(f"could not list pods in {namespace}")
    return json.loads(out).get("items", [])


def confirm_delete_existing(base, args):
    pods = list_managed_pods(base, args.debug_namespace)
    if not pods:
        return
    print(f"Found {len(pods)} existing pod(s) started by this script in {args.debug_namespace}:")
    for p in pods:
        node = p["metadata"].get("labels", {}).get(NODE_LABEL, "?")
        phase = p.get("status", {}).get("phase", "?")
        print(f"  {p['metadata']['name']}  node={node}  phase={phase}  "
              f"created={p['metadata'].get('creationTimestamp', '?')}")
    if not sys.stdin.isatty():
        raise PodsExist("existing pods found and stdin is not a terminal; run interactively to delete them, "
                        "or delete them manually")
    answer = input("Delete these pods and continue? [y/N] ").strip().lower()
    if answer not in ("y", "yes"):
        raise PodsExist("existing pods were not deleted; exiting without scanning")
    # By name, so only the pods listed above go; a label selector would also take other runs' pods.
    # In batches: thousands of names on one command line would exceed the kernel's argument limit.
    names = [p["metadata"]["name"] for p in pods]
    for i in range(0, len(names), DELETE_BATCH):
        batch = names[i:i + DELETE_BATCH]
        rc, _, err = run_capture(base + ["delete", "pods", "-n", args.debug_namespace, "--wait=false",
                                         "--ignore-not-found"] + batch, timeout=120)
        if rc != 0:
            raise PodsExist(f"could not delete existing pods: "
                            f"{error_line(err.decode(errors='replace'), 'unknown error')}")
    print("Deleted existing pods; continuing.", flush=True)


def node_label(node):
    """Label values are limited to 63 characters; shorten long node names with a hash."""
    if len(node) <= 63:
        return node
    return node[:52] + "-" + hashlib.sha256(node.encode()).hexdigest()[:10]


def pod_name_for(node):
    # Pod hostnames come from the pod name and are limited to 63 characters.
    slug = re.sub(r"[^a-z0-9-]", "-", node.lower()).strip("-")[:30].strip("-")
    return f"{POD_PREFIX}-{slug}-{secrets.token_hex(3)}"


def pod_manifest(args, node, pod_name):
    """Pod spec equivalent to `kubectl debug node/... --profile=sysadmin`, with our own name and labels."""
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": pod_name,
            "namespace": args.debug_namespace,
            "labels": {MANAGED_LABEL: "true", NODE_LABEL: node_label(node)},
        },
        "spec": {
            "nodeName": node,
            "hostPID": True,
            "hostIPC": True,
            "hostNetwork": True,
            "restartPolicy": "Never",
            "terminationGracePeriodSeconds": 5,  # PID 1 ignores SIGTERM; don't wait the default 30s
            # Backstop if the scanner dies without deleting its pod: kubelet ends the pod after this,
            # always past the scan's own --node-timeout, so a normal scan never reaches it.
            "activeDeadlineSeconds": int(args.node_timeout) + 600,
            "automountServiceAccountToken": False,
            "tolerations": [{"operator": "Exists"}],
            "containers": [{
                "name": DEBUG_CONTAINER,
                "image": args.image,
                "command": ["python3", "-c", "import signal; signal.pause()"],  # runs until deleted
                "securityContext": {"privileged": True, "runAsUser": 0, "readOnlyRootFilesystem": True},
                # requests == limits gives the pod Guaranteed QoS, so it isn't evicted mid-scan
                "resources": {"requests": {"cpu": args.pod_cpu, "memory": args.pod_memory},
                              "limits": {"cpu": args.pod_cpu, "memory": args.pod_memory}},
                "volumeMounts": [{"name": "host-root", "mountPath": NODE_ROOT}],
            }],
            "volumes": [{"name": "host-root", "hostPath": {"path": "/"}}],
        },
    }


def create_pod(base, args, node, pod_name):
    manifest = json.dumps(pod_manifest(args, node, pod_name)).encode()
    rc, _, err = run_capture(base + ["create", "-f", "-"], manifest, timeout=120)
    if rc != 0:
        detail = (f"kubectl exit {rc}" if rc is not None else "no response")
        raise RuntimeError(f"could not create pod: {error_line(err.decode(errors='replace'), detail)}")


# Runs the script from stdin. Its header (see stdin_payload) is read first and handed to the
# script as PRELOADED_CONFIG, so no secret ever appears on a command line.
BOOTSTRAP = (
    "import json, sys\n"
    "head, _, code = sys.stdin.buffer.read().partition(b'\\n')\n"
    "exec(compile(code, 'security_scan.py', 'exec'), {'__name__': '__main__', 'PRELOADED_CONFIG': json.loads(head), 'SCRIPT_SOURCE': code})\n"
)


def stdin_payload(script, passwords, salt=None):
    return json.dumps({"passwords": passwords, "salt": salt}).encode() + b"\n" + script


def exec_node(base, args, payload, pod, extra, name):
    """Run the in-pod scan. Its progress lines are relayed as they arrive, so a long scan is visible.

    It ends with a result, or with a stated reason: failed (with the pod's own error), silent for
    NODE_IDLE_TIMEOUT seconds (and the last thing it reported), or still running past --node-timeout.
    """
    cmd = base + ["exec", "-i", pod, "-n", args.debug_namespace, "-c", DEBUG_CONTAINER, "--",
                  "python3", "-c", BOOTSTRAP, "--node-root", NODE_ROOT] + extra

    def relay(line):
        if line.startswith(CHECKPOINT_PREFIX):
            try:
                saved = json.loads(line[len(CHECKPOINT_PREFIX):])
            except ValueError:
                log(name, f"unreadable checkpoint from the pod: {line[:80]}")
                return
            if CHECKPOINT is not None:
                CHECKPOINT.add_root(f"node/{name}", saved["root"], saved["piece"])
            return
        try:
            fields = json.loads(line[len(PROGRESS):]) if line.startswith(PROGRESS) else None
        except ValueError:
            fields = None
        if fields is not None:
            handle_progress(name, fields)
        else:
            log(name, line)

    outcome, rc, out, tail, progress = supervise(cmd, payload, idle=NODE_IDLE_TIMEOUT, overall=args.node_timeout,
                                                 on_line=relay)
    last = progress["last"] or "no output"
    if outcome == "idle":
        raise RuntimeError(f"debug pod {pod}: no output for {NODE_IDLE_TIMEOUT}s; last output was: {last}")
    if outcome == "overall":
        raise RuntimeError(f"debug pod {pod}: still running after the {args.node_timeout}s limit "
                           f"(--node-timeout); last output was: {last}")
    if rc != 0:
        reason = last_line(tail.decode(errors="replace"), f"kubectl exit {rc}")
        raise RuntimeError(f"scan failed in debug pod {pod}: {reason}")
    return json.loads(out)


def start_node(args, base, payload, name, created):
    """Start a debug pod on a node and return its network mounts (see network_entries)."""
    BOARD.set(name, phase="starting")
    log(name, "creating debug pod")
    pod = pod_name_for(name)
    created[name] = pod  # recorded before the create call: a create that times out may still have made it
    create_pod(base, args, name, pod)
    log(name, f"debug pod {pod} created")
    wait_for_pod(base, args, pod, name)
    log(name, f"debug pod {pod} running, reading mount table")
    return exec_node(base, args, payload, pod, ["--list-mounts"], name)["mounts"]


def release_pod(base, args, created, name, force=False, why=""):
    pod = created.pop(name, None)
    if pod:
        delete_pod(base, args, pod, name, force, why)


def scan_node_pod(args, base, stdin, name, created, runtime_hint, skip_mounts):
    extra = ["--runtime-hint", runtime_hint, "--emit-records", "--check", args.check]
    for mount in skip_mounts:
        extra += ["--skip-mount", mount]
    if args.reveal_names:
        extra.append("--reveal-names")
    for root in sorted(IGNORED_ROOTS):
        extra += ["--ignore-root", root]
    for root in (CHECKPOINT.roots(f"node/{name}") if CHECKPOINT is not None else {}):
        extra += ["--done-root", root]  # finished in an earlier run; the pod skips them
    pod = created[name]
    ns = args.debug_namespace

    def ignore_in_pod(root, pid, pod=pod):
        # The pod's walks re-read this file as they go, so the ignore takes effect without a restart.
        text = "".join(p + "\n" for p in sorted(IGNORED_ROOTS))
        run_capture(base + ["exec", "-i", pod, "-n", ns, "-c", DEBUG_CONTAINER, "--", "sh", "-c",
                            'cat > "$1.tmp" && mv "$1.tmp" "$1"', "sh", IGNORE_FILE],
                    data=text.encode(), timeout=30)

    IGNORER.handlers[name] = ignore_in_pod
    started = time.monotonic()
    BOARD.set(name, phase="scanning", started=started, done=0, total=None)
    payload = None
    try:
        payload = exec_node(base, args, stdin, pod, extra, name)
    except Exception as exc:
        BOARD.set(name, phase="stopped")
        log(name, f"stopped after {time.monotonic() - started:.0f}s: {exc}")
        raise
    finally:
        IGNORER.handlers.pop(name, None)
        failed = payload is None or bool(payload["failed"])
        if failed:
            log(name, f"pod state before deletion: {pod_post_mortem(base, args, pod)}")
        stalled = payload is not None and payload["stalled"]
        release_pod(base, args, created, name, force=stalled and args.force_stuck_pods,
                    why="scan failed" if failed else "scan complete")
        if payload is not None:
            for entry in payload["ignored"]:
                IGNORED_ROOTS.add(entry["root"])
                IGNORED_REPORT.append(dict(entry, target=f"node/{name}"))
    # Roots finished in an earlier run were not scanned by this pod; their saved results join this node's.
    saved = CHECKPOINT.roots(f"node/{name}") if CHECKPOINT is not None else {}
    payload["records"] = [r for piece in saved.values() for r in piece.get("records", [])] + payload["records"]
    payload["gaps"] = [g for piece in saved.values() for g in piece.get("gaps", [])] + payload["gaps"]
    payload["errors"] = list(dict.fromkeys(payload["errors"] + [w for piece in saved.values()
                                                                for w in piece.get("warnings", [])]))
    elapsed = time.monotonic() - started
    stats = payload["stats"]
    TOTALS["files"] += stats["files"]
    TOTALS["bytes"] += stats["bytes"]
    summary = (f"{stats['files']} files, {stats['bytes'] / 2**20:.1f} MiB in {elapsed / 60:.1f} min")
    BOARD.set(name, phase="stopped" if payload["failed"] else "done", done=stats["files"],
              total=stats["files"] if not payload["failed"] else None)
    log(name, f"scan {'stopped' if payload['failed'] else 'complete'}: {summary}")
    records = []
    for r in payload["records"]:
        if r["location"].startswith(NODE_ROOT):
            r["location"] = f"node/{name}:" + r["location"][len(NODE_ROOT):]
        records.append(r)
    if payload["failed"]:
        msg = payload["failed"]
        if payload["stalled"] and not args.force_stuck_pods:
            msg += (f"; debug pod {pod} left in place (it may stay Terminating until the mount recovers)")
        raise (ScanStalled if payload["stalled"] else ScanFailed)(msg, partial=records)
    info = [f"node/{name}: {line}" for line in payload["info"]] + [f"node/{name}: timing: {summary}"]
    gaps = [f"node/{name}: {g}" for g in payload["gaps"]]
    log(name, f"{len(records)} record(s)" + (f", {len(gaps)} gap(s)" if gaps else ""))
    return records, payload["errors"], info, gaps


def covers(ancestor, path):
    return path == ancestor or path.startswith(ancestor.rstrip("/") + "/")


def plan_mounts(inventories):
    """Decide which node scans each network path, and which mounts every node should skip.

    A mount is redundant when a mount of the same share already covers its backend path, i.e. the
    other path is an ancestor of it. The shallowest copy is kept; ties go to the lowest node name.
    """
    entries = sorted(((e, node) for node, mounts in inventories.items() for e in mounts),
                     key=lambda en: (len([p for p in en[0]["path"].split("/") if p]), en[1], en[0]["mount"]))
    kept, skip, info = [], {node: [] for node in inventories}, []
    for e, node in entries:
        cover = next((k for k in kept if k[0]["share"] == e["share"] and covers(k[0]["path"], e["path"])), None)
        if cover is None:
            kept.append((e, node))
            continue
        k, cnode = cover
        skip[node].append(e["mount"])
        info.append(f"🔁 {redact_backend(e['share'], e['export'], e['path'])}: skipped on node/{node}; "
                    f"covered by {redact_backend(k['share'], k['export'], k['path'])} on node/{cnode}")
    return skip, info


def scan_k8s(args, passwords):
    base = [args.kubectl] + (["--context", args.kube_context] if args.kube_context else [])
    selector = ["-l", args.selector] if args.selector else []
    out = run(base + ["get", "nodes"] + selector + ["-o", "json"])
    if out is None:
        raise RuntimeError(f"`{args.kubectl} get nodes` failed")
    nodes = []
    for node in json.loads(out).get("items", []):
        name = node["metadata"]["name"]
        if args.node and name not in args.node:
            continue
        version = node.get("status", {}).get("nodeInfo", {}).get("containerRuntimeVersion", "")
        nodes.append((name, version.split("://")[0]))
    if not nodes:
        raise RuntimeError("no matching nodes")
    COVERAGE["nodes_total"] = len(nodes)

    confirm_delete_existing(base, args)
    BOARD.start_ui()
    note(f"🚀 scanning {len(nodes)} node(s): {', '.join(name for name, _ in nodes)}")
    global REDACT_SALT
    REDACT_SALT = secrets.token_hex(16)
    with open(__file__, "rb") as f:
        stdin = stdin_payload(f.read(), passwords, REDACT_SALT)
    hints = dict(nodes)
    created, inventories = {}, {}
    records, errors, info, gaps = [], [], [], []
    done = set()  # nodes whose scan completed
    for name, _ in nodes:
        saved = CHECKPOINT.node(name) if CHECKPOINT is not None else {}
        if "result" in saved:
            inventories[name] = saved["mounts"]
            done.add(name)
            COVERAGE["nodes_scanned"] += 1
            r = saved["result"]
            records += r["records"]
            errors += r["errors"]
            info += r["info"]
            gaps += r["gaps"]
            note(f"node/{name}: finished in an earlier run; its saved results are used")

    def stop(name, exc, partial):
        # Terminate: say which node failed and which were not scanned, and keep what was found.
        pending = sorted(n for n, _ in nodes if n not in done and n != name)
        msg = f"{exc}; scan stopped"
        if pending:
            msg += f"; not scanned: {', '.join('node/' + p for p in pending)}"
        return ScanFailed(f"node/{name}: {msg}", partial=partial)

    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as ex:
            futures = {ex.submit(start_node, args, base, stdin, name, created): name
                       for name, _ in nodes if name not in done}
            for fut in concurrent.futures.as_completed(futures):
                name = futures[fut]
                try:
                    inventories[name] = fut.result()
                    if CHECKPOINT is not None:
                        CHECKPOINT.set_node(name, mounts=inventories[name])
                except Exception as exc:
                    ex.shutdown(wait=False, cancel_futures=True)
                    raise stop(name, exc, records) from exc

        skip, plan_info = plan_mounts(inventories)
        info += plan_info

        with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as ex:
            futures = {ex.submit(scan_node_pod, args, base, stdin, name, created,
                                 hints[name], skip[name]): name
                       for name in sorted(n for n in inventories if n not in done)}
            for fut in concurrent.futures.as_completed(futures):
                name = futures[fut]
                try:
                    r, e, i, g = fut.result()
                except Exception as exc:
                    ex.shutdown(wait=False, cancel_futures=True)
                    note(f"node/{name} failed first at {time.strftime('%H:%M:%S')}; "
                         f"stopping the other debug pods")
                    for other in list(created):
                        log(other, f"pod state before teardown: {pod_post_mortem(base, args, created[other])}")
                        release_pod(base, args, created, other, why=f"teardown: node/{name} failed first")
                    partial = records + (exc.partial if isinstance(exc, ScanFailed) else [])
                    raise stop(name, exc, partial) from exc
                records += r
                errors += e
                info += i
                gaps += g
                done.add(name)
                COVERAGE["nodes_scanned"] += 1
                if CHECKPOINT is not None:
                    CHECKPOINT.set_node(name, result={"records": r, "errors": e, "info": i, "gaps": g})
    finally:
        for name in list(created):
            release_pod(base, args, created, name)

    note(f"scanned {COVERAGE['nodes_scanned']} of {len(nodes)} node(s)")
    return records, errors, info, gaps


def scan_ssh(args, passwords):
    remote = ["python3", "-c", BOOTSTRAP, "--local", "--emit-records", "--check", args.check]
    if args.all:
        remote.append("--all")
    for path in args.path:
        remote += ["--path", path]
    remote_cmd = shlex.join((["sudo", "-n"] if args.sudo else []) + remote)
    with open(__file__, "rb") as f:
        payload_in = stdin_payload(f.read(), passwords)
    def relay(line):
        try:
            fields = json.loads(line[len(PROGRESS):]) if line.startswith(PROGRESS) else None
        except ValueError:
            fields = None
        if fields is not None:
            handle_progress(args.ssh, fields)
        else:
            BOARD.say(f"[{args.ssh}] {line}")

    BOARD.set(args.ssh, phase="connecting")
    outcome, rc, out, tail, progress = supervise(["ssh", args.ssh, remote_cmd], payload_in,
                                                 overall=SSH_TIMEOUT, on_line=relay)
    if outcome == "overall":
        raise RuntimeError(f"ssh to {args.ssh} did not finish within {SSH_TIMEOUT}s")
    if rc != 0:
        raise RuntimeError(tail.decode(errors="replace").strip() or f"ssh exit {rc}")
    payload = json.loads(out)
    BOARD.set(args.ssh, phase="done")
    for r in payload["records"]:
        r["location"] = f"{args.ssh}:{r['location']}"
    if payload["failed"]:
        raise (ScanStalled if payload["stalled"] else ScanFailed)(
            f"{args.ssh}: {payload['failed']}", partial=payload["records"])
    return (payload["records"], [f"{args.ssh}: {e}" for e in payload["errors"]],
            [f"{args.ssh}: {g}" for g in payload["gaps"]])


def load_blocklist(path):
    if not path:
        return []
    with open(path) as f:
        data = json.load(f)
    if isinstance(data, dict):
        data = data.get("spki_sha256", [])
    return [s.strip().lower() for s in data]


def classify(records, extra_spki):
    compromised_spki = set(extra_spki)
    for r in records:
        if r["method"] == "parsed" and r["spki"] and any(n in (r["subject"] or "") for n in COMPROMISED_CAS):
            compromised_spki.add(r["spki"])

    findings = []
    for r in records:
        if r["method"] == "version":
            continue
        if r["method"] == "raw":
            names = r["names"]
        else:
            names = [n for n in ALL_NAMES if n in (r["subject"] or "")]
        comp = [n for n in names if n in COMPROMISED_CAS]
        rel = [n for n in names if n in RELATED_CAS]

        if r["method"] == "parsed" and r["spki"] in compromised_spki:
            status = "COMPROMISED"
            names = comp or ["(same public key)"]
        elif comp and r["method"] == "raw":
            status = "NAME-MATCH"
        elif rel:
            status = "RELATED"
            names = rel
        else:
            continue
        findings.append({"kind": "certificate", "status": status, "location": r["location"],
                         "names": names, "subject": r["subject"], "spki": r["spki"]})
    return findings


def celebrate():
    tty = sys.stdout.isatty() and "NO_COLOR" not in os.environ

    def style(code, text):
        return f"\033[{code}m{text}\033[0m" if tty else text

    if tty:
        for frame in ["🔍", "🔎", "✨", "🎉", "🎊", "🥳", "✨"]:
            sys.stdout.write(f"\r  {frame}  checking certificate stores...")
            sys.stdout.flush()
            time.sleep(0.12)
        sys.stdout.write("\r" + " " * 50 + "\r")
    print(style("1;32", "  🎉 🥳  ALL CLEAR  🥳 🎉"))
    print(style("32", "  No compromised CAs or vulnerable PHP/Node.js versions found. ✅"))
    print(style("36", "  Your trust stores and keystores look clean. 🛡️"))


STATUS_GLYPHS = {"COMPROMISED": "🚨", "NAME-MATCH": "⚠️", "RELATED": "🔗",
                 "OK": "✅", "VULNERABLE": "☠️", "UNKNOWN": "❓"}


def coverage_line():
    line = f"🔎 Coverage: {TOTALS['files']:,} files ({TOTALS['bytes'] / 2**20:.1f} MiB) read"
    if COVERAGE["nodes_total"]:
        line += f"; nodes scanned {COVERAGE['nodes_scanned']} of {COVERAGE['nodes_total']}"
    return line


def print_report(findings, errors, info, gaps, failed=None, ignored=()):
    if failed:
        print(f"❌ SCAN FAILED: {failed}")
        print("   The scan was terminated. Findings below are partial; nothing else was checked.\n")
    print(coverage_line() + "\n")
    if ignored:
        print("⏭️  Ignored directories (not scanned, by request):")
        for e in ignored:
            read = f"; {e['files']:,} files read" if e.get("files") else ""
            print(f"  {e.get('target', ''):<16} {e['root']}  ({e['how']}{read})")
        print()
    if gaps:
        print(f"🚧 SCAN INCOMPLETE: {len(dict.fromkeys(gaps))} target(s) were not scanned:")
        for g in dict.fromkeys(gaps):
            print(f"  ❌ {g}")
        print()
    if info:
        print("📦 Detected storage:")
        for line in info:
            print(f"  {line}")
        print()
    certs = [f for f in findings if f["kind"] == "certificate"]
    runtimes = [f for f in findings if f["kind"] == "runtime"]
    rank = {"COMPROMISED": 0, "NAME-MATCH": 1, "RELATED": 2}
    for f in sorted(certs, key=lambda f: (rank[f["status"]], f["location"])):
        detail = f["subject"] or ", ".join(f["names"])
        spki = f"  spki={f['spki'][:16]}..." if f["spki"] else ""
        print(f"{STATUS_GLYPHS[f['status']]} {f['status']:<12} {f['location']}")
        print(f"{'':<15}🔑 {detail}{spki}")
    counts = {s: sum(1 for f in certs if f["status"] == s) for s in rank}
    print(f"\n📊 🚨 COMPROMISED: {counts['COMPROMISED']}  ⚠️  NAME-MATCH: {counts['NAME-MATCH']}  "
          f"🔗 RELATED: {counts['RELATED']}")

    if runtimes:
        print("\n🧪 Runtime versions:")
        summary = Counter((f["runtime"], f["version"], f["status"], f["detail"]) for f in runtimes)
        for (runtime, version, status, detail), n in sorted(summary.items()):
            plural = "s" if n != 1 else ""
            print(f"  {STATUS_GLYPHS[status]} {status:<12} {runtime} {version}  ({n} location{plural}; {detail})")
        for f in sorted((f for f in runtimes if f["status"] != "OK"), key=lambda f: f["location"]):
            print(f"{STATUS_GLYPHS[f['status']]} {f['status']:<12} {f['location']}")
            print(f"{'':<15}📎 {f['runtime']} {f['version']} from {f['source']}")
        vuln = sum(1 for f in runtimes if f["status"] == "VULNERABLE")
        unknown = sum(1 for f in runtimes if f["status"] == "UNKNOWN")
        print(f"\n📊 ☠️  RUNTIME VULNERABLE: {vuln}  ❓ UNKNOWN: {unknown}")

    problems = any(f["kind"] == "certificate" or f["status"] != "OK" for f in findings)
    nothing_read = TOTALS["files"] == 0
    if not failed and not gaps and not errors and not problems and not ignored and not nothing_read:
        print()
        celebrate()
    elif not problems:
        reason = "nothing was read, so nothing was checked" if nothing_read \
            else "nothing found, but coverage was incomplete (see below)"
        print(f"\n❓ NOT ALL CLEAR: {reason}.")
    if errors:
        print("\n⚠️  Warnings/errors:")
        for e in dict.fromkeys(errors):
            print(f"  - {e}")


def open_state(args, roots):
    """The saved progress for this scan: a new one, or the unfinished run that --resume continues."""
    sig = json.dumps({"k8s": args.k8s, "local": args.local, "ssh": args.ssh, "check": args.check,
                      "roots": sorted(roots), "nodes": sorted(args.node or []), "selector": args.selector,
                      "image": args.image}, sort_keys=True)
    path = os.path.expanduser(args.state_file)
    if args.discard_state:
        with contextlib.suppress(FileNotFoundError):
            os.remove(path)
    saved = ScanState.read(path)
    if saved is None:
        return ScanState(path, sig)
    if saved.get("signature") != sig:
        raise RuntimeError(f"{path} holds an unfinished scan with different settings; run with the same "
                           f"settings and --resume, or with --discard-state to start over")
    if not args.resume:
        raise RuntimeError(f"an unfinished scan is saved in {path}; run with --resume to continue it, "
                           f"or with --discard-state to start over")
    IGNORED_ROOTS.update(saved.get("ignored", []))
    IGNORED_REPORT.extend(saved.get("ignored_report", []))
    finished_roots = sum(len(v) for v in saved["roots"].values())
    finished_nodes = sum(1 for v in saved["nodes"].values() if "result" in v)
    print(f"resuming the scan saved in {path}: {finished_roots} finished root(s), "
          f"{finished_nodes} finished node(s)", file=sys.stderr)
    return ScanState(path, sig, saved)


def main():
    ap = argparse.ArgumentParser(
        description="Scan hosts, containers, and Kubernetes nodes for compromised CA certificates and vulnerable PHP/Node.js versions.",
        epilog="Pick at least one target: --local, --ssh, --container-runtime, or --k8s.")
    ap.add_argument("--local", action="store_true", help="scan this host")
    ap.add_argument("--path", action="append", default=[],
                    help="root to scan with --local/--ssh (repeatable; default: standard certificate locations)")
    ap.add_argument("--all", action="store_true",
                    help="scan the entire filesystem with --local/--ssh instead of standard locations")
    ap.add_argument("--ssh", metavar="HOST", help="scan a remote host over ssh")
    ap.add_argument("--sudo", action="store_true", help="run the remote scan with 'sudo -n'")
    ap.add_argument("--container-runtime", choices=["docker", "podman"],
                    help="scan all running containers on this host")
    ap.add_argument("--k8s", action="store_true",
                    help="scan every node's container storage via a debug pod on each node; PersistentVolumes "
                         "mounted on several nodes are scanned once (requires --image)")
    ap.add_argument("--image", help="debug image with python3 and openssl, e.g. python:3.14-slim (required with --k8s)")
    ap.add_argument("--node", action="append", default=[],
                    help="only scan this node with --k8s (repeatable; default: all nodes)")
    ap.add_argument("-l", "--selector", help="label selector to choose nodes for --k8s")
    ap.add_argument("-n", "--debug-namespace", default=DEBUG_NAMESPACE,
                    help=f"namespace for the --k8s debug pods (default: {DEBUG_NAMESPACE})")
    ap.add_argument("--node-timeout", type=int, default=NODE_TIMEOUT,
                    help=f"with --k8s, seconds one node's scan may run in total (default: {NODE_TIMEOUT}); "
                         f"a scan that goes silent for {NODE_IDLE_TIMEOUT}s is stopped regardless")
    ap.add_argument("--pod-cpu", default="1",
                    help="CPU limit (and request) for each --k8s debug pod (default: 1)")
    ap.add_argument("--pod-memory", default="2Gi",
                    help="memory limit (and request) for each --k8s debug pod (default: 2Gi)")
    ap.add_argument("--force-stuck-pods", action="store_true",
                    help="with --k8s, force-delete a debug pod whose scan process is stuck on a stalled mount. "
                         "Off by default: a force-deleted container can keep running on the node, unseen, until "
                         "the mount recovers")
    ap.add_argument("--kubectl", default="kubectl", help="kubectl or oc binary (default: kubectl)")
    ap.add_argument("--kube-context", help="kubeconfig context to use")
    ap.add_argument("--password", action="append", default=[],
                    help="extra keystore password to try (repeatable)")
    ap.add_argument("--blocklist", help="JSON file with extra SPKI SHA-256 hashes (list or {\"spki_sha256\": [...]})")
    ap.add_argument("--workers", type=int, default=8, help="parallel nodes/containers (default: 8)")
    ap.add_argument("--json", action="store_true", help="print findings as JSON")
    ap.add_argument("--json-out", metavar="FILE",
                    help="also write the results to FILE as JSON, even if the scan failed or was incomplete")
    ap.add_argument("--ignore-related", action="store_true",
                    help="hide RELATED findings (trusted emSign/AAA roots) from output and exit code")
    ap.add_argument("--check", choices=["certs", "runtimes", "all"], default="all",
                    help="certificate checks, PHP/Node.js version checks, or both (default: all)")
    ap.add_argument("--emit-records", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--node-root", help=argparse.SUPPRESS)
    ap.add_argument("--runtime-hint", help=argparse.SUPPRESS)
    ap.add_argument("--list-mounts", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--skip-mount", action="append", default=[], help=argparse.SUPPRESS)
    ap.add_argument("--ignore-root", action="append", default=[], help=argparse.SUPPRESS)
    ap.add_argument("--done-root", action="append", default=[], help=argparse.SUPPRESS)
    ap.add_argument("--ignore-file", default=None, help=argparse.SUPPRESS)
    ap.add_argument("--resume", action="store_true",
                    help="continue the unfinished scan saved in --state-file")
    ap.add_argument("--discard-state", action="store_true",
                    help="throw away the saved progress in --state-file and start over")
    ap.add_argument("--state-file", default=STATE_PATH,
                    help=f"where finished roots and nodes are saved during a run (default: {STATE_PATH})")
    ap.add_argument("--reveal-names", action="store_true",
                    help="with --k8s, show Secret and PV names and server:/export paths instead of salted hashes")
    ap.add_argument("--scan-root", help=argparse.SUPPRESS)
    ap.add_argument("--skip-path", action="append", default=[], help=argparse.SUPPRESS)
    ap.add_argument("--no-skip", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--prefix", default="", help=argparse.SUPPRESS)
    ap.add_argument("--mountinfo", default="/proc/self/mountinfo", help=argparse.SUPPRESS)
    ap.add_argument("--count-only", action="store_true", help=argparse.SUPPRESS)
    args = ap.parse_args()

    global REDACT_SALT, REVEAL_NAMES, SCAN_CERTS, SCAN_RUNTIMES, HEARTBEAT, PROGRESS_SINK
    REVEAL_NAMES = args.reveal_names
    SCAN_CERTS = args.check in ("certs", "all")
    SCAN_RUNTIMES = args.check in ("runtimes", "all")
    cfg = globals().get("PRELOADED_CONFIG")
    if cfg is not None:
        passwords = cfg["passwords"]
        REDACT_SALT = cfg.get("salt") or ""
    else:
        passwords = DEFAULT_PASSWORDS + args.password
    if args.scan_root:
        # A root's own process, started by scan_local. The operator can ignore the root mid-run: SIGUSR1
        # makes this process write out what it has so far, marked ignored, and exit. A process that has
        # not installed the handler yet dies of the signal, which the parent also reads as ignored.
        HEARTBEAT = True

        def ignore_now(signum, frame):
            if args.count_only:
                payload = {"count": COUNT_STATE["n"], "ignored": True}
            else:
                payload = {"records": CHILD_STATE["records"], "gaps": [], "warnings": WARNINGS,
                           "stats": STATS, "ignored": True}
            sys.stdout.write(json.dumps(payload))
            sys.stdout.flush()
            os._exit(0)

        configure_child(args.prefix, args.ignore_file)
        signal.signal(signal.SIGUSR1, ignore_now)
        if args.count_only:
            pseudo = pseudo_mountpoints(args.prefix, args.mountinfo)
            n = count_files(args.scan_root, not args.no_skip, set(), frozenset(args.skip_path), pseudo)
            json.dump({"count": n}, sys.stdout)
            return 0
        records, gaps = scan_local([args.scan_root], passwords, skip=not args.no_skip,
                                   skip_paths=frozenset(args.skip_path), prefix=args.prefix,
                                   mountinfo=args.mountinfo, isolate=False)
        json.dump({"records": records, "gaps": gaps, "warnings": WARNINGS, "stats": STATS}, sys.stdout)
        return 0
    if args.node_root:
        PROGRESS_SINK = stderr_sink
        try:
            if args.list_mounts:
                roots, _ = probe_node(args.node_root)
                json.dump({"mounts": network_entries(read_mounts(), roots, args.node_root)}, sys.stdout)
            else:
                json.dump(node_payload(args, passwords), sys.stdout)
        except RuntimeError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        return 0

    if not any([args.local, args.ssh, args.container_runtime, args.k8s]):
        ap.print_help()
        return 3
    if args.k8s and not args.image:
        print("error: --k8s requires --image (a debug image with python3 and openssl, e.g. python:3.14-slim)",
              file=sys.stderr)
        return 3
    # Certificates are parsed on this machine only for --local and --container-runtime; --ssh and
    # --k8s run the same checks remotely (and report their tool gaps through the payload).
    parses_here = (args.local or args.container_runtime) and SCAN_CERTS
    if parses_here and not shutil.which("openssl"):
        print("error: openssl is required for certificate checks on this machine "
              "(use --check runtimes to skip them)", file=sys.stderr)
        return 3

    roots = args.path or (["/"] if args.all else DEFAULT_ROOTS)
    records, errors, info, gaps = [], [], [], []

    if parses_here and not shutil.which("keytool"):
        info.append("keytool not found: JKS/JCEKS stores are checked by raw byte search only")
    if args.local and os.geteuid() != 0:
        errors.append("not running as root: unreadable files are skipped")

    failed, stalled = None, False
    global CHECKPOINT
    if not args.emit_records:
        try:
            CHECKPOINT = open_state(args, roots)
        except RuntimeError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 6
    # A remote scan (--emit-records) reports to its stderr for the controller; a local one draws its own bar.
    PROGRESS_SINK = stderr_sink if args.emit_records else board_sink
    if not args.emit_records:
        IGNORER.handlers["local"] = stop_local_root
        if not args.k8s:
            BOARD.start_ui()  # the k8s scan starts it after its prompt about existing pods
    try:
        if args.local:
            r, g = scan_local(roots, passwords)
            records += r
            gaps += g
            for entry in IGNORED_REPORT:
                entry.setdefault("target", "local")
        if args.ssh:
            r, e, g = scan_ssh(args, passwords)
            records += r
            errors += e
            gaps += g
        if args.container_runtime:
            r, e = scan_runtime(args.container_runtime, passwords, args.workers)
            records += r
            errors += e
        if args.k8s:
            r, e, i, g = scan_k8s(args, passwords)
            records += r
            errors += e
            info += i
            gaps += g
    except PodsExist as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 6
    except ScanFailed as exc:
        # Terminated: keep what was found, and say so.
        records += exc.partial
        failed, stalled = str(exc), isinstance(exc, ScanStalled)
    except (RuntimeError, json.JSONDecodeError) as exc:
        errors.append(str(exc))
        gaps.append(str(exc))

    BOARD.stop_ui()  # the report goes to the normal terminal; the panel would redraw over it
    if CHECKPOINT is not None:
        if failed:
            BOARD.say(f"progress is saved in {CHECKPOINT.path}; run again with --resume to continue")
        else:
            CHECKPOINT.finish()
    errors += [w for w in WARNINGS if w not in errors]
    if args.emit_records:
        json.dump({"records": records, "errors": errors, "gaps": gaps, "failed": failed, "stalled": stalled},
                  sys.stdout)
        return 0

    findings = []
    if args.check in ("certs", "all"):
        findings += classify(records, load_blocklist(args.blocklist))
        if args.ignore_related:
            findings = [f for f in findings if f["status"] != "RELATED"]
    if args.check in ("runtimes", "all"):
        findings += runtime_findings(records)
    code = exit_code(findings, failed, gaps, errors)
    report = {"generated": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "exit_code": code,
              "detected": info, "findings": findings, "errors": errors, "incomplete": gaps,
              "failed": failed, "stalled": stalled, "ignored": IGNORED_REPORT,
              "coverage": {"files": TOTALS["files"], "bytes": TOTALS["bytes"], **COVERAGE}}
    if args.json_out:
        write_json_file(os.path.expanduser(args.json_out), report)
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print_report(findings, errors, info, gaps, failed, IGNORED_REPORT)
    return code


def exit_code(findings, failed, gaps, errors):
    if any(f["kind"] == "certificate" and f["status"] in ("COMPROMISED", "NAME-MATCH") for f in findings):
        return 2
    if any(f["kind"] == "runtime" and f["status"] != "OK" for f in findings):
        return 4
    if any(f["kind"] == "certificate" for f in findings):
        return 1
    if failed or gaps or errors or IGNORED_REPORT or TOTALS["files"] == 0:
        return 5
    return 0


def write_json_file(path, obj):
    """Writes the results as one JSON document, atomically and readable by this user only."""
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


if __name__ == "__main__":
    try:
        sys.exit(main())
    finally:
        BOARD.stop_ui()  # restores the terminal before any traceback is printed
        with contextlib.suppress(FileNotFoundError):
            os.remove(LOCAL_IGNORE_FILE)
