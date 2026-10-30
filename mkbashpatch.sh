#!/sw/bash/bin/bash

set -euo pipefail

script_dir="${BASH_SOURCE[0]%/*}"
if test "$script_dir" == "${BASH_SOURCE[0]}"
then
    script_dir="."
fi
root="$(cd "$script_dir" && pwd)"

if test $# -lt 1
then
    echo "Usage: $0 <archive...>" >&2
    exit 1
fi

python3 - "$root" "$@" << 'EOF'
import os
import sys
import glob
import re
import shutil
import subprocess
import tempfile

root_dir = sys.argv[1]
sw_dir = os.path.join(root_dir, "sw")
os.makedirs(sw_dir, exist_ok=True)

archives = sys.argv[2:]

doc_exts = {".po", ".pot", ".gmo", ".texi", ".info", ".md", ".rst", ".html",
            ".1", ".2", ".3", ".4", ".5", ".6", ".7", ".8", ".9", ".man", ".doc", ".txt"}
doc_prefixes = ("changelog", "changes", "news", "readme", "copying", "license", "authors", "thanks", "todo")

for archive in archives:
    archive_path = archive
    if not os.path.isfile(archive_path):
        candidate = os.path.join(root_dir, "packages", archive)
        if os.path.isfile(candidate):
            archive_path = candidate
        else:
            candidate = os.path.join(root_dir, "work", "archives", archive)
            if os.path.isfile(candidate):
                archive_path = candidate
            else:
                print(f"Error: archive not found: {archive}", file=sys.stderr)
                sys.exit(1)

    tmpdir = tempfile.mkdtemp(prefix="fluffy-patch-")
    try:
        extract_dir = os.path.join(tmpdir, "extract")
        os.makedirs(extract_dir, exist_ok=True)
        subprocess.run(["tar", "-xf", archive_path, "-C", extract_dir], check=True)

        entries = [e for e in os.listdir(extract_dir) if not e.startswith(".")]
        if len(entries) == 1 and os.path.isdir(os.path.join(extract_dir, entries[0])):
            dir_name = entries[0]
            work_dir = os.path.join(tmpdir, dir_name)
            orig_dir = os.path.join(tmpdir, f"{dir_name}.orig")
            src_dir = os.path.join(extract_dir, dir_name)
            shutil.copytree(src_dir, orig_dir, symlinks=True)
            shutil.move(src_dir, work_dir)
        else:
            filename = os.path.basename(archive_path)
            base = re.sub(r"\.tar\.[a-zA-Z0-9]+$", "", filename)
            base = re.sub(r"\.tgz$", "", base)
            dir_name = base
            work_dir = os.path.join(tmpdir, dir_name)
            orig_dir = os.path.join(tmpdir, f"{dir_name}.orig")
            shutil.copytree(extract_dir, orig_dir, symlinks=True)
            shutil.move(extract_dir, work_dir)

        changed_files = 0
        for root, dirs, files in os.walk(work_dir):
            dirs[:] = [d for d in dirs if d != ".git"]
            for f in files:
                path = os.path.join(root, f)
                if os.path.islink(path):
                    continue
                fname = f.lower()
                if any(fname.startswith(p) for p in doc_prefixes) or any(fname.endswith(ext) for ext in doc_exts):
                    continue
                try:
                    with open(path, "rb") as fp:
                        raw = fp.read()
                except Exception:
                    continue
                if b"\0" in raw:
                    continue

                text = raw.decode("latin-1")
                # Replace shebangs
                s1 = re.sub(r"^#!\s*/bin/(ba)?sh(\s|$)", r"#!/sw/bash/bin/bash\2", text, flags=re.MULTILINE)
                # Replace other references to /bin/bash and /bin/sh (negative lookbehind avoids /sw/bash)
                s2 = re.sub(r"(?<!/sw/bash)/bin/(ba)?sh\b", r"/sw/bash/bin/bash", s1)
                if s2 != text:
                    st = os.stat(path)
                    with open(path, "wb") as fp:
                        fp.write(s2.encode("latin-1"))
                    os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns))
                    changed_files += 1

        patch_filename = f"{dir_name}-fluffy.patch"
        patch_path = os.path.join(sw_dir, patch_filename)

        diff_env = dict(os.environ, TZ="UTC0", LC_ALL="C")
        diff_proc = subprocess.run(
            ["diff", "-Naur", "--no-dereference", f"{dir_name}.orig", dir_name],
            cwd=tmpdir,
            capture_output=True,
            text=True,
            env=diff_env
        )

        patch_content = diff_proc.stdout
        # Normalize diff header to match existing patch style
        patch_content = re.sub(r"^diff -Naur --no-dereference ", "diff -Naur ", patch_content, flags=re.MULTILINE)

        if patch_content.strip():
            with open(patch_path, "w", encoding="utf-8") as fp:
                fp.write(patch_content)
            line_count = len(patch_content.splitlines())
            print(f"Created sw/{patch_filename} ({changed_files} files changed, {line_count} diff lines)")
        else:
            print(f"No /bin/bash or /bin/sh references found in {archive_path}")

    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
EOF
