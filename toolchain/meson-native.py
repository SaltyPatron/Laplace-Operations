# The floating-point contract (determinism.tsv) as a Meson native file, for builds Meson drives (PostgreSQL):
#   python meson-native.py <msvc|gnu> <laplace-math library> > native.ini
import os
import sys

driver, math = sys.argv[1], sys.argv[2]
compile_, link = [], []
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "determinism.tsv"), encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\r\n")
        if not line or not line[0].isalpha():
            continue
        what, d, value = line.split("\t", 2)
        if d not in ("any", driver):
            continue
        if what == "compile":
            compile_.append(value)
        elif what == "link":
            link.append(value)
        elif what == "nobuiltin":
            compile_ += [f"/clang:-fno-builtin-{fn}" if driver == "msvc" else f"-fno-builtin-{fn}" for fn in value.split()]
winlibs = None
if driver == "msvc":
    # laplace-math's 128-bit conversions come from the compiler's own runtime; Meson links with link.exe, which does
    # not know the compiler's library directory, so the runtime is named by its full path.
    import subprocess
    resource = subprocess.run(["icx", "/clang:-print-resource-dir"], capture_output=True, text=True).stdout.strip()
    builtins = os.path.join(resource, "lib", "windows", "clang_rt.builtins-x86_64.lib")
    if not os.path.isfile(builtins):
        sys.exit(f"meson-native: no compiler runtime at {builtins}")
    # link.exe resolves a reference from the libraries after the one that made it before it wraps around, and libmmd
    # (Intel's libm) is every icx object's default library: a static library listed after laplace-math would take sin
    # from it. So libmmd is no default library, and the Windows libraries, which close every Meson link line, end with
    # laplace-math and then libmmd for the exact operations (determinism.tsv). Not in c_link_args: Meson's library
    # checks link with those but without the Windows libraries, and laplace-math needs libmmd.
    link = ["/NODEFAULTLIB:libmmd.lib"] + link
    winlibs = ["kernel32.lib", "user32.lib", "gdi32.lib", "winspool.lib", "shell32.lib", "ole32.lib", "oleaut32.lib",
               "uuid.lib", "comdlg32.lib", "advapi32.lib", math, builtins, "libmmd.lib"]
else:
    link = [f"-Wl,--whole-archive,{math},--no-whole-archive"] + link

def arr(xs):
    return "[" + ", ".join("'" + x.replace("\\", "/").replace("'", "\\'") + "'" for x in xs) + "]"

print("[binaries]")
print("c = 'icx'" if driver == "msvc" else "c = 'icx'\ncpp = 'icpx'")
print("\n[built-in options]")
print("c_args = " + arr(compile_))
print("c_link_args = " + arr(link))
if winlibs:
    print("c_winlibs = " + arr(winlibs))
