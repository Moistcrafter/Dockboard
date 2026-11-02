"""Run inside LLDB's Python interpreter; no shell or persistent service."""
import json
import os
from pathlib import Path
import subprocess

BUILD = "26B123"
DOCK_UUID = "C53975B1-2956-3ED4-B699-D4CE2E6A602C"
DOCK = "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"
MODULES = (
    ("TransitionBase", "GenieSpringBoardV5"),
    ("GlobalRouting", "GenieSpringBoardGlobal"),
    ("Duration", "GenieIPadDuration"),
    ("Composition", "GenieCompositionV8"),
    ("NativeWarp", "DockboardNativeWarp"),
    ("WindowLevel", "GenieTransitionLevel"),
    ("Crossfade", "GenieCrossfadeV24"),
    ("InputRouting", "DockboardInputRouting"),
    ("RestoreAcknowledgement", "EarlyRestoreAckV2"),
)
TOGGLES = tuple(prefix for _, prefix in MODULES[1:-1])


def run_command(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


def preflight():
    build = run_command("/usr/sbin/sysctl", "-n", "kern.osversion")
    if build != BUILD:
        raise RuntimeError(f"Unsupported macOS build {build}; this build supports {BUILD} only.")
    uuid = run_command("/usr/bin/xcrun", "dwarfdump", "--uuid", DOCK)
    if DOCK_UUID not in uuid:
        raise RuntimeError("Dock binary does not match this version.")
    if "status: disabled." not in run_command("/usr/bin/csrutil", "status"):
        raise RuntimeError("This experimental version requires SIP to be disabled. No settings were changed.")
    return build


def state_from_values(statuses, flags, acknowledgement):
    installed = all(value == 1 for value in statuses.values())
    enabled = installed and all(flags.values()) and acknowledgement == 0xFFFFFFFF
    partial = any(flags.values()) or acknowledgement != 0
    return "enabled" if enabled else "partial" if partial else "native"


def control(action, directory):
    if action not in ("status", "enable", "disable"):
        raise ValueError("Unknown action")
    build = preflight()
    import lldb
    debugger = lldb.debugger
    debugger.SetAsync(False)
    target = debugger.CreateTarget(DOCK)
    error = lldb.SBError()
    pids = run_command("/usr/bin/pgrep", "-u", str(os.getuid()), "-x", "Dock").splitlines()
    if len(pids) != 1:
        raise RuntimeError("Could not identify one Dock process for the current user.")
    process = target.AttachToProcessWithID(debugger.GetListener(), int(pids[0]), error)
    if error.Fail():
        raise RuntimeError(f"Could not attach to Dock: {error.GetCString()}")
    try:
        main = next((thread for thread in process if thread.GetQueueName() == "com.apple.main-thread"), None)
        if main is None:
            raise RuntimeError("Dock's main thread is unavailable; try again when idle.")
        frame = main.GetFrameAtIndex(0)
        options = lldb.SBExpressionOptions()
        options.SetLanguage(lldb.eLanguageTypeObjC_plus_plus)
        options.SetTimeoutInMicroSeconds(2_000_000)

        def evaluate(expression):
            value = frame.EvaluateExpression(expression, options)
            if value.GetError().Fail():
                raise RuntimeError(value.GetError().GetCString())
            return value.GetValueAsUnsigned()

        def symbol(name):
            return evaluate(f'(unsigned long long)((void *(*)(void *, const char *))dlsym)((void *)-2,{json.dumps(name)})')

        def read(name, ctype="int"):
            address = symbol(name)
            return evaluate(f"*({ctype} *){address}") if address else 0

        def call(name, argument, ctype="bool"):
            address = symbol(name)
            if not address or not evaluate(f"((bool (*)({ctype})){address})({argument})"):
                raise RuntimeError(f"Runtime operation failed: {name}")

        statuses = {prefix: read(prefix + "Status") for _, prefix in MODULES}
        if action != "status":
            if symbol("GenieCrossfadeV23Status") or (statuses["GenieSpringBoardV5"] and read("DockboardConcurrentRuntimeVersion") != 1):
                raise RuntimeError("An older runtime is loaded. Restart Dock before loading this build.")
            if read("GenieCrossfadeV24PendingWindow", "unsigned"):
                raise RuntimeError("An animation is in progress. Try again when it finishes.")
            if action == "enable":
                if statuses["GenieSpringBoardV5"] and not all(v == 1 for v in statuses.values()) and not symbol("DockboardInstallWarpInterceptorV2"):
                    raise RuntimeError("An older partial runtime is loaded. Restart Dock before loading this build.")
                for module, prefix in MODULES:
                    if statuses[prefix] == 1:
                        continue
                    if symbol(prefix + "Status"):
                        raise RuntimeError(f"{module} previously rejected this process. Restart Dock before retrying.")
                    path = (directory / (module + ".dylib")).resolve(strict=True)
                    if not evaluate(f'(unsigned long long)((void *(*)(const char *,int))dlopen)({json.dumps(str(path), ensure_ascii=False)},10)'):
                        raise RuntimeError(f"Could not load {module}.")
                    statuses[prefix] = read(prefix + "Status")
                    if statuses[prefix] != 1:
                        raise RuntimeError(f"{module} rejected the runtime layout.")
                try:
                    for prefix in TOGGLES:
                        call(prefix + "SetEnabled", "true")
                    call("EarlyRestoreAckV2Select", "4294967295u", "unsigned")
                except Exception as original:
                    # Restore every enabled component, even when a different component refuses cleanup.
                    failures = []
                    try:
                        call("EarlyRestoreAckV2Select", "0", "unsigned")
                    except RuntimeError as exc:
                        failures.append(str(exc))
                    for prefix in reversed(TOGGLES):
                        try:
                            call(prefix + "SetEnabled", "false")
                        except RuntimeError as exc:
                            failures.append(str(exc))
                    if failures:
                        raise RuntimeError(f"{original}; cleanup incomplete: {'; '.join(failures)}") from original
                    raise
            else:
                failures = []
                if statuses["EarlyRestoreAckV2"] == 1:
                    try:
                        call("EarlyRestoreAckV2Select", "0", "unsigned")
                    except RuntimeError as exc:
                        failures.append(str(exc))
                for prefix in reversed(TOGGLES):
                    if statuses[prefix] == 1:
                        try:
                            call(prefix + "SetEnabled", "false")
                        except RuntimeError as exc:
                            failures.append(str(exc))
                if failures:
                    raise RuntimeError("; ".join(failures))
        flags = {prefix: read(prefix + "Enabled") for prefix in TOGGLES}
        state = state_from_values(statuses, flags, read("EarlyRestoreAckV2Window", "unsigned"))
        return {"ok": True, "state": state, "build": build, "pid": process.GetProcessID()}
    finally:
        detached = process.Detach()
        if detached.Fail():
            raise RuntimeError(f"Could not detach from Dock: {detached.GetCString()}")


if __name__ == "__main__":
    try:
        result = control(os.environ["DOCKBOARD_ACTION"], Path(os.environ["DOCKBOARD_RUNTIME_DIR"]))
    except Exception as exc:
        result = {"ok": False, "state": "unavailable", "message": str(exc)}
    Path(os.environ["DOCKBOARD_RESULT"]).write_text(json.dumps(result))
