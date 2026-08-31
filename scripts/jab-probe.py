"""Read the running app's accessibility tree the way a Windows screen reader does.

WHY THIS EXISTS, and why the step it replaces was worse than nothing.

The workflow used to answer "is this app accessible on Windows?" with a UI Automation probe.
That probe reported, every time, "descendant elements exposed: 1, ControlType.Pane name=''",
and that was read as proof that Compose Desktop publishes no accessibility information. It is
not proof of anything. Compose Desktop does not implement UI Automation on Windows at all; it
publishes a javax.accessibility tree, and the Java Access Bridge is what carries that tree to
Narrator, NVDA and JAWS. UI Automation cannot see Access Bridge content by design. So the old
step asked a question in a language the app has never spoken, got silence, and the silence was
recorded in FIXLIST.md as "it needs Compose Desktop to implement Windows accessibility".

An instrument that returns the same answer whether the thing works or not is not a measurement.
This one asks through the bridge, which is the same path a screen reader takes, so its answer
means something in both directions.

HOW IT WORKS

WindowsAccessBridge-64.dll is the assistive-technology side of the bridge and ships in every
JDK's bin directory. The application side lives inside the app's own bundled runtime and is
switched on by Main.kt. The two halves talk over Windows messages, which is why this pumps a
message loop: without one the bridge never finishes discovering the running VM and every call
returns false, which looks exactly like an app with no accessibility.
"""

import argparse
import ctypes
import ctypes.wintypes as wintypes
import os
import pathlib
import sys
import time

MAX_STRING_SIZE = 1024
SHORT_STRING_SIZE = 256

jint = ctypes.c_int32
JOBJECT64 = ctypes.c_int64  # the 64 bit bridge passes contexts as jlong, not as a pointer


class AccessibleContextInfo(ctypes.Structure):
    """AccessBridgePackages.h. Field order and widths are load bearing: ctypes does not
    validate this against the DLL, so a wrong layout returns plausible garbage rather than an
    error."""

    _fields_ = [
        ("name", ctypes.c_wchar * MAX_STRING_SIZE),
        ("description", ctypes.c_wchar * MAX_STRING_SIZE),
        ("role", ctypes.c_wchar * SHORT_STRING_SIZE),
        ("role_en_US", ctypes.c_wchar * SHORT_STRING_SIZE),
        ("states", ctypes.c_wchar * SHORT_STRING_SIZE),
        ("states_en_US", ctypes.c_wchar * SHORT_STRING_SIZE),
        ("indexInParent", jint),
        ("childrenCount", jint),
        ("x", jint),
        ("y", jint),
        ("width", jint),
        ("height", jint),
        ("accessibleComponent", ctypes.c_int32),
        ("accessibleAction", ctypes.c_int32),
        ("accessibleSelection", ctypes.c_int32),
        ("accessibleText", ctypes.c_int32),
        ("accessibleInterfaces", ctypes.c_int32),
    ]


def find_bridge_dll(explicit):
    """The AT side of the bridge. Any JDK's copy will do; it is not tied to the app's runtime."""
    if explicit:
        return pathlib.Path(explicit)
    roots = []
    for var in ("JAVA_HOME", "JAVA_HOME_17_X64", "JAVA_HOME_21_X64"):
        if os.environ.get(var):
            roots.append(pathlib.Path(os.environ[var]))
    roots.append(pathlib.Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32")
    for root in roots:
        for candidate in (root / "bin" / "WindowsAccessBridge-64.dll", root / "WindowsAccessBridge-64.dll"):
            if candidate.exists():
                return candidate
    return None


def pump(user32, seconds):
    """The bridge is asynchronous and message driven. Nothing it is asked works until the VM it
    is talking to has announced itself, and that announcement arrives as a window message."""
    msg = wintypes.MSG()
    deadline = time.time() + seconds
    while time.time() < deadline:
        while user32.PeekMessageW(ctypes.byref(msg), None, 0, 0, 1):  # PM_REMOVE
            user32.TranslateMessage(ctypes.byref(msg))
            user32.DispatchMessageW(ctypes.byref(msg))
        time.sleep(0.02)


def top_level_windows(user32, title):
    """EnumWindows rather than FindWindow, so a near miss can be reported with the titles that
    were actually on screen instead of a bare "not found"."""
    found = []
    seen = []
    proto = ctypes.WINFUNCTYPE(ctypes.c_bool, wintypes.HWND, wintypes.LPARAM)

    def callback(hwnd, _lparam):
        if not user32.IsWindowVisible(hwnd):
            return True
        length = user32.GetWindowTextLengthW(hwnd)
        if length == 0:
            return True
        buffer = ctypes.create_unicode_buffer(length + 1)
        user32.GetWindowTextW(hwnd, buffer, length + 1)
        seen.append(buffer.value)
        if buffer.value == title:
            found.append(hwnd)
        return True

    user32.EnumWindows(proto(callback), 0)
    return found, seen


def walk(bridge, vm_id, context, depth, out, limit):
    """Depth first, and deliberately unbounded in breadth. A tree that is rich at the root and
    empty two levels down is still an app a screen reader cannot read, so the count that this
    returns has to come from the whole thing."""
    info = AccessibleContextInfo()
    if not bridge.getAccessibleContextInfo(vm_id, context, ctypes.byref(info)):
        return 0, 0
    named = 1 if info.name.strip() else 0
    total = 1
    if len(out) < limit:
        out.append(
            "  " * depth
            + f"{info.role_en_US or info.role or '?'}"
            + (f"  name='{info.name}'" if info.name.strip() else "  name=''")
            + (f"  states={info.states_en_US}" if info.states_en_US else "")
        )
    for index in range(info.childrenCount):
        child = bridge.getAccessibleChildFromContext(vm_id, context, index)
        if not child:
            continue
        child_total, child_named = walk(bridge, vm_id, child, depth + 1, out, limit)
        total += child_total
        named += child_named
        bridge.releaseJavaObject(vm_id, child)
    return total, named


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--title", default="The Long View")
    parser.add_argument("--dll", default=None)
    parser.add_argument("--min-named", type=int, default=0,
                        help="fail if fewer than this many elements carry a name. 0 reports only.")
    parser.add_argument("--print-limit", type=int, default=200)
    parser.add_argument("--settle-seconds", type=float, default=8.0)
    args = parser.parse_args()

    dll_path = find_bridge_dll(args.dll)
    if not dll_path:
        print("::error::WindowsAccessBridge-64.dll not found. Looked in JAVA_HOME\\bin and System32.")
        return 1
    print(f"bridge dll: {dll_path}")

    user32 = ctypes.windll.user32
    bridge = ctypes.CDLL(str(dll_path))

    bridge.Windows_run.restype = None
    bridge.isJavaWindow.argtypes = [wintypes.HWND]
    bridge.isJavaWindow.restype = ctypes.c_bool
    bridge.getAccessibleContextFromHWND.argtypes = [wintypes.HWND, ctypes.POINTER(ctypes.c_int32), ctypes.POINTER(JOBJECT64)]
    bridge.getAccessibleContextFromHWND.restype = ctypes.c_bool
    bridge.getAccessibleContextInfo.argtypes = [ctypes.c_int32, JOBJECT64, ctypes.POINTER(AccessibleContextInfo)]
    bridge.getAccessibleContextInfo.restype = ctypes.c_bool
    bridge.getAccessibleChildFromContext.argtypes = [ctypes.c_int32, JOBJECT64, jint]
    bridge.getAccessibleChildFromContext.restype = JOBJECT64
    bridge.releaseJavaObject.argtypes = [ctypes.c_int32, JOBJECT64]
    bridge.releaseJavaObject.restype = None

    bridge.Windows_run()
    pump(user32, args.settle_seconds)

    windows, seen = top_level_windows(user32, args.title)
    if not windows:
        print(f"::error::No visible top level window titled '{args.title}'. Windows on screen:")
        for title in seen:
            print(f"  '{title}'")
        return 1

    # isJavaWindow can be false for a beat after the window paints, because the bridge registers
    # the VM on its own schedule. Retrying costs seconds; not retrying costs a false negative
    # that reads exactly like the bug this step exists to catch.
    hwnd = windows[0]
    for _ in range(10):
        if bridge.isJavaWindow(hwnd):
            break
        pump(user32, 1.0)
    else:
        print("::error::The bridge does not recognise the app window as a Java window.")
        print("         The app side of the bridge did not load. Check that jdk.accessibility is")
        print("         in the jpackage modules list and that Main.kt set assistive_technologies.")
        return 1

    vm_id = ctypes.c_int32()
    context = JOBJECT64()
    if not bridge.getAccessibleContextFromHWND(hwnd, ctypes.byref(vm_id), ctypes.byref(context)):
        print("::error::isJavaWindow said yes but no accessible context came back for the window.")
        return 1

    lines = []
    total, named = walk(bridge, vm_id.value, context, 0, lines, args.print_limit)
    print(f"accessible elements: {total}, of which named: {named}")
    for line in lines:
        print(line)
    if len(lines) >= args.print_limit:
        print(f"  ... printed the first {args.print_limit} of {total}")

    if args.min_named and named < args.min_named:
        print(f"::error::Only {named} named elements. A screen reader needs at least {args.min_named} here.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
