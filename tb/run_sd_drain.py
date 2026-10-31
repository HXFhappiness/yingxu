#!/usr/bin/env python3
"""Reproduce P0 regressions, CTRLPHASE coverage, and P1 source experiments.

Run at any working directory: python3 tb/run_sd_drain.py
Requires iverilog/vvp and fetched exp/s1b-{a,b,c} commits. Never builds a bitstream.
"""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "out/s1b_hw"
OUT.mkdir(parents=True, exist_ok=True)
CORE = "src/user_source/hdl_source/media/sd/sd_stream_reader_core.v"
RAM = "src/user_source/hdl_source/media/sd/ram_dual_port_simple.v"
HDL = "src/user_source/hdl_source/"
TB = "tb/tb_sd_drain.v"
VARIANTS = {"A": "abbb173", "B": "4da1a9c", "C": "1bcee71"}


def run(command, log):
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=240)
    (OUT / log).write_text(result.stdout, encoding="utf-8")
    if result.returncode:
        raise RuntimeError(f"exit={result.returncode}: {command!r}\n{result.stdout}")
    return {"argv": command, "exit": result.returncode, "log": log}


def case(name, top, core=CORE, mode=None, extra=(), args=(), expect_bad=0):
    image = f"out/s1b_hw/{name}.vvp"
    compile_cmd = ["iverilog", "-g2012", "-s", top, "-o", image]
    if mode is not None:
        compile_cmd.append(f"-P{top}.MODE={mode}")
    if expect_bad:
        compile_cmd.append(f"-P{top}.EXPECT_BAD=1")
    compile_cmd.extend([TB, core, RAM, *extra])
    start = time.monotonic()
    commands = [run(compile_cmd, name+".compile.log"),
                run(["vvp", image, *args], name+".log")]
    return {"name": name, "commands": commands, "wall_seconds": time.monotonic()-start}


def main():
    sources = {}
    for label, ref in VARIANTS.items():
        blob = subprocess.check_output(["git", "show", ref+":"+CORE], cwd=ROOT)
        path = OUT / ("core_"+label+".v")
        path.write_bytes(blob)
        sources[label] = {"commit": subprocess.check_output(
            ["git", "rev-parse", ref], cwd=ROOT, text=True).strip(),
            "sha256": hashlib.sha256(blob).hexdigest()}
    jobs = [dict(name="drain", top="tb_sd_drain"),
            dict(name="ctrlphase", top="tb_sd_ctrlphase")]
    for mode in (0, 1):
        prefix = "p0" if mode == 0 else "single"
        jobs.extend([
            dict(name=prefix+"_bmp", top="tb_sd_bmp", mode=mode,
                 extra=[HDL+"yingxu_bmp_loader.v"]),
            dict(name=prefix+"_wav48", top="tb_sd_wav", mode=mode,
                 extra=[HDL+"yingxu_wav_player.v"], args=["+file=tb/assets/tb_tune.yxm"]),
            dict(name=prefix+"_wav44", top="tb_sd_wav", mode=mode,
                 extra=[HDL+"yingxu_wav_player.v"], args=["+file=tb/assets/tb_tune44.yxm"]),
            dict(name=prefix+"_cart", top="tb_sd_cart", mode=mode,
                 extra=[HDL+"yx8_cart_soc.v", HDL+"yx8_cpu.v"],
                 args=["+file=cartridges/invaders.yxc"])])
    for label in VARIANTS:
        jobs.append(dict(name="experiment_"+label, top="tb_sd_variant",
                         core=f"out/s1b_hw/core_{label}.v", expect_bad=int(label=="A")))
    for label in ("B", "C"):
        jobs.append(dict(name="experiment_"+label+"_cart", top="tb_sd_cart", mode=1,
                         core=f"out/s1b_hw/core_{label}.v",
                         extra=[HDL+"yx8_cart_soc.v", HDL+"yx8_cpu.v"],
                         args=["+file=cartridges/invaders.yxc"]))
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures = {pool.submit(case, **job): job["name"] for job in jobs}
        for future in concurrent.futures.as_completed(futures):
            result = future.result()
            results.append(result)
            print(f"{result['name']}: exit=0", flush=True)
    evidence = {"variants": sources, "results": sorted(results, key=lambda x: x["name"]),
                "sha256": {f: hashlib.sha256((ROOT/f).read_bytes()).hexdigest()
                           for f in (CORE, TB, RAM, "cartridges/invaders.yxc")}}
    (OUT/"results.json").write_text(json.dumps(evidence, indent=2)+"\n", encoding="utf-8")
    print("Software checks complete; board acceptance and root cause remain open.")


if __name__ == "__main__":
    main()
