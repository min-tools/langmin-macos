#!/usr/bin/env python3
"""Run the app's offline fixtures. Each suite writes a separate log."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
import argparse
import json
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


# run_suites(root, logs, [jobs = 2], [scripts = None], [swift_suites = ()],
# [environment = None]): Run isolated fixture suites with bounded concurrency,
# timeouts, and per-suite logs.
def run_suites(root, logs, jobs=2, *, scripts=None, swift_suites=(), environment=None):
    root, logs = Path(root), Path(logs)
    logs.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update(environment or {})
    env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    env.setdefault('LANGMIN_TEST_MODULE_CACHE', str(logs / 'modules'))
    scripts = scripts if scripts is not None else sorted((root / 'scripts').glob('test_*.py'))
    tasks = [(p.stem, [sys.executable, str(p)]) for p in scripts if p.name != 'test_all.py']
    # Compile standalone Swift fixtures alongside Python-driven suites.
    for name, sources in swift_suites:
        executable = logs / name
        tasks.append((name, ['swiftc', '-module-cache-path', env['LANGMIN_TEST_MODULE_CACHE'],
                             *map(str, sources), '-o', str(executable)]))

    # run(task): Execute one suite and return its name with a process-style exit
    # status.
    def run(task):
        name, command = task
        with (logs / (name + '.log')).open('w') as output:
            # Capture compilation and execution output in the same suite log.
            try:
                result = subprocess.run(command, cwd=root, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=300)
                # Run a standalone Swift executable only after it compiled successfully.
                if result.returncode == 0 and command[0] == 'swiftc':
                    result = subprocess.run([str(logs / name)], cwd=root, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=120)
                return name, result.returncode
            # Represent a timed-out suite with an explicit failure code and log message.
            except subprocess.TimeoutExpired:
                output.write('\nSuite exceeded its time limit.\n')
                return name, 124

    results = {}
    # Native focus tests share WindowServer. Run them after the parallel fixtures so
    # one test window cannot take keyboard focus from another test process.
    focus_names = {'test_result_text_editor', 'test_titlebar_zoom', 'test_audio_transcription', 'test_launcher_input_placeholder'}
    focus_tasks = [task for task in tasks if task[0] in focus_names]
    tasks = [task for task in tasks if task[0] not in focus_names]
    with ThreadPoolExecutor(max_workers=jobs) as executor:
        # Report parallel fixture results as each suite completes.
        for future in as_completed([executor.submit(run, task) for task in tasks]):
            name, code = future.result()
            results[name] = code
            print(f'{"PASS" if code == 0 else "FAIL"} {name}', flush=True)
    # Run focus-sensitive fixtures sequentially so their windows do not steal each other's focus.
    for task in focus_tasks:
        name, code = run(task)
        results[name] = code
        print(f'{"PASS" if code == 0 else "FAIL"} {name}', flush=True)
    (logs / 'results.json').write_text(json.dumps(results, indent=2, sort_keys=True) + '\n')
    passed = sum(code == 0 for code in results.values())
    print(f'{passed}/{len(results)} suites passed. Logs: {logs}', flush=True)
    return 0 if passed == len(results) else 1


# Configure the full fixture run when this script is invoked directly.
if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--logs', type=Path)
    parser.add_argument('--jobs', type=int, choices=range(1, 5), default=2)
    args = parser.parse_args()
    logs = args.logs or Path(tempfile.mkdtemp(prefix='langmin-checks-', dir='/private/tmp'))
    standalone = [('test_launcher_logic', [ROOT/'langmin/Sources/LangminApp/LauncherLogic.swift', ROOT/'scripts/test_launcher_logic.swift']),
                  ('test_text_watermark_cleaner', [ROOT/'langmin/Sources/LangminApp/TextWatermarkCleaner.swift', ROOT/'scripts/test_text_watermark_cleaner.swift'])]
    standalone.append(('test_pro_entitlements', [ROOT/'langmin/Sources/LangminApp/ProEntitlementLogic.swift', ROOT/'scripts/test_pro_entitlements.swift']))
    sys.exit(run_suites(ROOT, logs, args.jobs, swift_suites=standalone))
