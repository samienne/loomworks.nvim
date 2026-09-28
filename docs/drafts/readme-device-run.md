# DRAFT — README outline: "Running on a device"

<!-- Outline for a new README section (after "Deploy steps", and a matching
     subsection under "Standalone `lw` runner" → Commands). To be written
     with the implementation (core §18). -->

## Running on a device

1. **When this applies** — a profile whose kit cross-compiles (from an SDK such
   as DevEco Studio). loomworks never runs such a binary on your PC; it runs it
   on an attached device, or tells you why it can't.
2. **Prerequisites** — the SDK declared (`lw sdk add …`), a device attached and
   authorised; the SDK plugin must ship a device runner.
3. **Pick a device** — `lw device list`; one device is picked automatically;
   with several use `--device <serial>` or persist with `lw device select`.
   Editor: picker on first launch, remembered per profile.
4. **What gets copied** — the program, the project libraries it links, the
   platform runtime, plus what you list in the project's `device` block
   (`stage` / `archive` globs relative to the build directory). Layout is
   preserved, so `../../assets` still works. Only changed files are re-sent;
   `--fresh` re-sends all. Example: the LumeScene API test runner.
5. **Run** — `lw run <profile> <target> -- <args>`; output streams, the exit
   code is the program's, crash reports are pulled to
   `<build>/.device-runs/<time>-<serial>/` (last 10 runs kept) with
   `output.log` (stdout+stderr) and `device.log` (the device's own log).
6. **Device logs** — what is shown and how it is filtered is the platform
   plugin's: `--log key=value` per run, `device_log = { … }` in a launch
   configuration. HarmonyOS: native programs show stdout and print the last
   hilog lines on failure; `--log show=both --log level=D --log tag=…`.
   Link to the ohos plugin's docs for the option list.
7. **Test** — `lw test <profile> --target <exe> [--junit out.xml] -- --gtest_filter=…`.
   Why plain `lw test` (ctest) refuses on a cross profile.
8. **Timeouts and hangs** — transport timeouts (`--query-timeout`,
   `--transfer-timeout`), device-disconnect detection, `--timeout` for the program, Ctrl-C stops the program on the device.
9. **Sharing a device** — one run at a time per device (lock; `--no-wait`,
   `lw unlock --device`, `LOOMWORKS_DEVICE_LOCK_DIR`).
10. **Clean up** — `lw device clean`.
11. **Trust** — `stage`/`archive` and `device_log` may come from `loomworks.json`; device `env`
    and `working_dir` only from your local config (`lw help trust`).
12. **Limits (v1)** — no stdin, no debugging on device, no test explorer for
    device tests, ctest-registered tests not yet run on device.
