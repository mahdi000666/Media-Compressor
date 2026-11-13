import argparse
import os
import pathlib
import re
import subprocess
import tempfile
import zipfile


ROOT = pathlib.Path(__file__).resolve().parent.parent
SDK = pathlib.Path(os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT") or ROOT / ".tools/android-sdk")
DEXDUMP = SDK / "build-tools/36.0.0" / ("dexdump.exe" if os.name == "nt" else "dexdump")
CONFIG = "Lcom/antonkarpenko/ffmpegkit/FFmpegKitConfig;"
ABI = "Lcom/antonkarpenko/ffmpegkit/AbiDetect;"
CALLBACKS = {
    ("log", "(JI[B)V"),
    ("statistics", "(JIFFJDDD)V"),
    ("safOpen", "(I)I"),
    ("safClose", "(I)I"),
}
NATIVES = {
    ABI: {
        ("getNativeAbi", "()Ljava/lang/String;"),
        ("getNativeCpuAbi", "()Ljava/lang/String;"),
        ("isNativeLTSBuild", "()Z"),
        ("getNativeBuildConf", "()Ljava/lang/String;"),
    },
    CONFIG: {
        ("enableNativeRedirection", "()V"),
        ("disableNativeRedirection", "()V"),
        ("getNativeLogLevel", "()I"),
        ("setNativeLogLevel", "(I)V"),
        ("getNativeFFmpegVersion", "()Ljava/lang/String;"),
        ("getNativeVersion", "()Ljava/lang/String;"),
        ("nativeFFmpegExecute", "(J[Ljava/lang/String;)I"),
        ("nativeFFprobeExecute", "(J[Ljava/lang/String;)I"),
        ("nativeFFmpegCancel", "(J)V"),
        ("messagesInTransmit", "(J)I"),
        ("registerNewNativeFFmpegPipe", "(Ljava/lang/String;)I"),
        ("getNativeBuildDate", "()Ljava/lang/String;"),
        ("setNativeEnvironmentVariable", "(Ljava/lang/String;Ljava/lang/String;)I"),
        ("ignoreNativeSignal", "(I)V"),
    },
}
CONTRACT = {ABI: NATIVES[ABI], CONFIG: NATIVES[CONFIG] | CALLBACKS}
LIBRARIES = {
    "libffmpegkit_abidetect.so": ABI,
    "libffmpegkit.so": CONFIG,
    "libffmpegkit_armv7a_neon.so": CONFIG,
}


def check(apk_path, dexdump_path=DEXDUMP):
    found = {descriptor: {} for descriptor in CONTRACT}
    libraries = {descriptor: 0 for descriptor in CONTRACT}
    with zipfile.ZipFile(apk_path) as apk, tempfile.TemporaryDirectory() as temp:
        folder = pathlib.Path(temp)
        for name in apk.namelist():
            descriptor = LIBRARIES.get(pathlib.PurePosixPath(name).name)
            if descriptor:
                native = apk.read(name)
                symbols = {descriptor[1:-1].encode(), *(value.encode() for pair in CONTRACT[descriptor] for value in pair)}
                if any(symbol + b"\0" not in native for symbol in symbols):
                    raise RuntimeError(f"Review the JNI registration contract for {name}.")
                libraries[descriptor] += 1
            if not re.fullmatch(r"classes\d*\.dex", name):
                continue
            dex = folder / name
            dex.write_bytes(apk.read(name))
            dump = folder / "dex.txt"
            with dump.open("wb") as output:
                subprocess.run(
                    [str(dexdump_path), str(dex)],
                    stdout=output, stderr=subprocess.PIPE, check=True,
                )
            active = None
            methods = False
            method = None
            signature = None
            with dump.open(encoding="utf-8", errors="replace") as output:
                for line in output:
                    match = re.search(r"Class descriptor\s+: '([^']+)'", line)
                    if match:
                        active = match.group(1) if match.group(1) in CONTRACT else None
                        methods = False
                    if not active:
                        continue
                    if "Direct methods" in line or "Virtual methods" in line:
                        methods = True
                    if not methods:
                        continue
                    match = re.match(r"\s+name\s+: '([^']+)'", line)
                    if match:
                        method = match.group(1)
                        signature = None
                    match = re.match(r"\s+type\s+: '([^']+)'", line)
                    if match:
                        signature = match.group(1)
                    match = re.match(r"\s+access\s+: 0x([0-9a-fA-F]+)", line)
                    if match:
                        found[active][(method, signature)] = int(match.group(1), 16)
    failures = []
    for descriptor, expected in CONTRACT.items():
        if libraries[descriptor] == 0:
            failures.append(f"Missing native library for {descriptor}")
        for method in sorted(expected):
            required = 0x108 if method in NATIVES[descriptor] else 0x8
            if found[descriptor].get(method, 0) & required != required:
                failures.append(f"Missing JNI declaration/access: {descriptor} {method[0]}{method[1]}")
    if failures:
        raise RuntimeError("\n".join(failures))
    print(f"PASS: all 18 native registrations and four callbacks retain class/method names, signatures and access ({sum(libraries.values())} native libraries checked).")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("apk", type=pathlib.Path)
    parser.add_argument("--dexdump", type=pathlib.Path, default=DEXDUMP)
    args = parser.parse_args()
    check(args.apk, args.dexdump)
