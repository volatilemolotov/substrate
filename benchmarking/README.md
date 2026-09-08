# Substrate Benchmarking

This is the nascent suite for benchmarking Substrate's performance at scale.

The suite also measures the telemetry volume and the capacity of the OTel
collector: how much trace data and metric data substrate and its actors send,
and if the collector can accept it. To make a measurement, read
[telemetry/README.md](telemetry/README.md). For the prerequisites and the
scenario ladder, read [observability.md](observability.md).

## Deploy benchmarks

> [!IMPORTANT]
> Source the environment configuration file (e.g., `source .ate-dev-env.sh`)
> first so `PROJECT_ID`, `BUCKET_NAME`, etc. are set.

Note that deploying the benchmarks does not run them. You must visit Locust's
web UI to start a test.

A single wrapper deploys the scale workloads, builds and pushes the Locust
image, then deploys the Locust workers:

```bash
./benchmarking/deploy_locust.sh --deploy
```

Useful flags:

* `--worker-count N` — number of `WorkerPool` replicas (default 1).
* `--skip-build` — reuse the existing `:latest` locust image (skip the
  `docker build && docker push` step).

To tear everything down (locust then workloads, in reverse order):

```bash
./benchmarking/deploy_locust.sh --delete
```

The same operations are also reachable from the top-level installer for
convenience:

```bash
./hack/install-ate.sh --deploy-benchmarks
./hack/install-ate.sh --delete-benchmarks
```

The installer accepts `--benchmark-worker-count N` (default `1`).
`--skip-build` is only available when invoking
`benchmarking/deploy_locust.sh` directly.

## Running Tests

### Locust Web UI
* Run `kubectl port-forward svc/locust -n benchmarking 8089:8089`
* Visit `http://localhost:8089` in your browser to configure and start the load test.

The different user classes you can select are different types of load behaviors
you can throw at the system. Note that the "CounterUser" load type requires
that the counter demo be installed.

You can also configure things like the number of users, how quickly those users
are spawned, the frequency with which requests are made and whether or not tracing is
enabled.

User classes implemented in boomer rather than Python are selected at deploy
time — the stack runs one per deployment:

```bash
./benchmarking/locust/deploy.sh --deploy --user-class durdir
```

### Headless (automation only)

`runner.py` runs a test without the web UI, writing CSVs, logs and traces to
`--dest`. The nightly automation submits it as a Job on the test cluster; it is
not a local entry point. See [automation/README.md](automation/README.md).

```bash
python3 runner.py -f tests/<user-class>.py -t 1m -u 1 --name <run-name> --dest /tmp/bench
```

Test-specific flags are appended to the same command; see the sections below.

### DurDir Benchmark

The DurDir benchmark evaluates actor suspend/resume performance, disk persistence overhead,
and state restoration latency when a durable directory is attached to the actor.

#### DurDir Configuration Knobs

* `--durdir-file-size-bytes`: Size in bytes of the data file (default `8388608` = 8 MiB).
* `--resume-mode`: Resume trigger mode:
  * `explicit` (default): Client invokes the `ResumeActor` RPC before sending traffic.
  * `implicit`: Client sends traffic through the router without an explicit wake RPC, testing traffic-triggered resume.
* `--durdir-read-mode`: Verification read mode:
  * `data` (default): Server returns full payload bytes for client-side SHA-256 verification.
  * `digest`: Server hashes the file and returns size and digest, reducing network transfer.
* `--durdir-template`: ActorTemplate name:
  * `glutton-durdir-data` (default): Attaches a durable data directory without memory snapshot restore.
  * `glutton-durdir-full`: Attaches a durable data directory and performs a full memory snapshot restore.

#### DurDir Reported Metrics

* `DurDirWrite`: Initial truncate-write creating the data file.
* `DurDirServeInitial`: First read immediately following file creation.
* `SuspendActor`: Actor suspend latency (snapshot creation + persistence upload).
* `ResumeActor`: Actor resume latency.
* `DurDirServeAfterResume`: First read after resume (measures page faults / lazy load overhead on restored volume).
* `DurDirServeWarm`: Subsequent read within the same active cycle (cached state baseline).
* `DurDirOverwrite`: In-place file overwrite with checksum verification.

### TTFI Benchmark

TTFI — time to first instruction — measures the wall clock a client waits
before a sandbox accepts work. It is not the sum of the other benchmarks'
rows: `ResumeActor` returning is not the same as the actor being reachable,
and under implicit resume no `ResumeActor` RPC is issued at all. The window
opens when the client wants the sandbox and closes when an instruction comes
back correct, including the routing hop and any retry a real client would
have made.

Two windows are reported, because they answer different questions:

* `TTFIColdStart`: a newly created actor with no snapshot of its own —
  starting a new session.
* `TTFIWarmStart`: an actor that exists and was suspended to object storage —
  resuming an existing session. This is the number substrate's 100ms
  activation target is about.

#### TTFI Configuration Knobs

* `--resume-mode`: who triggers the activation (shared with the DurDir
  benchmark):
  * `explicit` (default): the client calls `ResumeActor`, then sends the
    instruction.
  * `implicit`: no wake RPC — traffic reaches the router, which parks the
    request and wakes the actor. This is the path a real agent harness takes.
    It needs [request parking](../docs/request-parking.md) enabled, or the
    retries absorb 503s and TTFI reads high.
* `--ttfi-cold-source`: what supplies guest state on a cold start. `golden`
  (default) restores the template's golden snapshot; `coldboot` skips it and
  starts the containers from the OCI image. Rides on the `ResumeActor` boot
  flag, so it applies to `--resume-mode explicit` only.
* `--ttfi-template`: the ActorTemplate to measure (default `glutton`). Point
  it at a template on another sandbox class or snapshot scope to compare them.
* `--ttfi-timeout`: seconds to keep retrying the first instruction before
  recording the window as a failure (default `60`).

#### TTFI Reported Metrics

* `TTFIColdStart` / `TTFIWarmStart`: the measurement — client wall clock for
  the whole window. Unlike the other rows these deliberately do **not** use
  the server's elapsed trailer: the gaps between phases are precisely what
  TTFI measures, and a server-side number cannot see them.
* `TTFIResume`: the `ResumeActor` RPC, in explicit mode only.
* `TTFIInstruction`: the retry loop until an instruction is accepted.
* `TTFISuspend`: the suspend that precedes each warm window. A precondition,
  not part of the measurement — it runs outside the TTFI span.

#### Reading a TTFI trace

The row's latency is its parent span's duration, and each phase is a child
span, so one sampled trace explains its own total without joining anything.
The parent carries the split as attributes:

| Attribute | Meaning |
|---|---|
| `ttfi.total_ms` | the measurement |
| `ttfi.control_plane_ms` | ateapi's own handler time, from the server trailer |
| `ttfi.instruction_ms` | the instruction phase, retries included |
| `ttfi.attempts` | instructions sent before one was accepted |
| `ttfi.resume_mode`, `ttfi.cold`, `ttfi.cold_source`, `ttfi.template` | which window this was |

`ttfi.total_ms` minus `control_plane_ms` minus `instruction_ms` is the time
substrate spent outside its own handlers — scheduling, snapshot fetch, and
sandbox restore. Expand the `ateapi` `step.*` children of the same trace to
see which of those it was.

### Viewing Traces
You must have enabled otel tracing for your cluster to view traces.

You can find trace IDs by viewing the `logs` tab in the Locust UI

## Optional: Prometheus + Grafana

Locust provides graphs, statistics, etc. via the UI. However, you
can install Prometheus/Grafana if you want richer details or
the ability to perform deeper analysis. Skip this section if
you're only using the Locust web UI.

```bash
kubectl apply -f benchmarking/monitoring.yaml
```

Once installed:

* Run `kubectl port-forward svc/grafana -n benchmarking 3000:3000`
* Visit `http://localhost:3000` in your browser.

## Development

### Rebuilding gRPC Python clients

`hack/update/codegen.sh` regenerates them along with the rest of the generated
code; it manages its own virtual environment under `locust/codegen/venv`.
`hack/verify/codegen.sh` fails if the checked-in clients have drifted from the
protos.
