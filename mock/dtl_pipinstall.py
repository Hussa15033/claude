"""Cross-platform pip installer launcher for IRIS Embedded Python.

Invoked out-of-process as:  <embedded-python> dtl_pipinstall.py <target-dir> <pkg> [pkg ...]

Installs the given packages INTO <target-dir> (the IRIS <mgr>/python directory,
which is first on Embedded Python's sys.path on every OS). Run via a 2-arg
$ZF(-100) call (interpreter + this script) because passing `-m pip install ...`
as separate $ZF(-100) varargs proved unreliable, whereas a single script file is
robust. Writes a result line the caller can read; exit code reflects success.
"""
import sys
import subprocess


def main():
    if len(sys.argv) < 3:
        print("RESULT=ERR usage: dtl_pipinstall.py <target> <pkg>...")
        return 2
    target = sys.argv[1]
    pkgs = sys.argv[2:]
    cmd = [sys.executable, "-m", "pip", "install",
           "--target", target, "--upgrade",
           "--disable-pip-version-check"] + pkgs
    try:
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        sys.stdout.write(r.stdout or "")
        print("RESULT=" + ("OK" if r.returncode == 0 else "ERR rc=%d" % r.returncode))
        return r.returncode
    except Exception as e:
        print("RESULT=ERR " + str(e))
        return 1


if __name__ == "__main__":
    sys.exit(main())
