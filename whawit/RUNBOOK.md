# Astronomy Shop — Whawit demo & test environment

Internal runbook. The fork of [open-telemetry/opentelemetry-demo](https://github.com/open-telemetry/opentelemetry-demo)
plays the role of a customer: 18 real microservices in 11 languages (frontend, cart, checkout,
product-catalog, currency, payment, shipping, quote, email, recommendation, ad, fraud-detection,
accounting, image-provider, flagd, flagd-ui, load-generator, frontend-proxy) plus Kafka, Valkey,
PostgreSQL, and the OTel Collector, Jaeger, Prometheus, Grafana and OpenSearch. Upstream docs:
<https://opentelemetry.io/docs/demo/>.

Everything Whawit-specific lives in the two upstream customization seams
(`compose.extras.yaml`, `src/otel-collector/otelcol-config-extras.yml`), in `.env.override`
(non-secret) and in this `whawit/` directory. Sync from upstream with
`git fetch upstream && git merge upstream/main`; those seams are designed not to conflict.

## Where it runs

| Piece | Where |
|---|---|
| VM | GCE `otel-demo`, project `whawit`, `us-central1-a`, e2-standard-4 (4 vCPU / 16 GB), Debian 12, 80 GB |
| Access | IAP tunnels only, no inbound rule from the internet (`whawit/vm.sh ssh`, `whawit/vm.sh tunnel`) |
| Service account | `otel-demo-vm@whawit.iam.gserviceaccount.com`: logging/monitoring/trace writer + accessor on its two secrets |
| Stack | `/opt/astronomy-shop`, `make start` (compose + full + observability + extras) |
| Recordings | `/opt/astronomy-shop/recordings/{traces,logs,metrics}.jsonl` (OTLP JSON, rotated at 200 MB, 7 days) |

Cost: roughly US$100/month running 24×7. **Stop it between demos** (`whawit/vm.sh stop`); a stopped VM
only bills the disk. `whawit/vm.sh start` boots the whole stack again from the startup script.

## Whawit side (sandbox)

| Object | Value |
|---|---|
| Instance | `sandbox.whawit.ai` / `sandbox.services.whawit.ai`, db `whawit-sandbox` |
| Org / project | `urn:org:seed-acme` (Acme) / `urn:project:astronomy-shop` "Astronomy Shop", key `ASTRO` |
| OTLP ingest | `POST https://sandbox.services.whawit.ai/ingest/otlp/v1/{traces,logs,metrics}` with `x-whawit-api-key` + `x-whawit-project-id` |
| Collector api key | Secret Manager `whawit-otel-demo-api-key` (apikey doc `urn:apikey:949de91e…`, user jes@us3.group). Rotate: delete the doc, re-run the provisioning, add a secret version |
| Whawit Collector integration | auto-created on first ingest (`vendor: whawit`, `type: otel`) |
| GCP integration | `GCP Astronomy Shop` `urn:integration:4ac934fe…`, scope `logName = projects/whawit/logs/astronomy-shop` (OAuth secret copied from `GCP ACME`) |
| GitHub integration | `GitHub Astronomy Shop` `urn:integration:4a1722a1…`, repo `WHAWIT/astronomy-shop` (secrets copied from `GitHub ACME`) |
| Change webhook | Secret Manager `whawit-otel-demo-change-webhook-url` (posted by `whawit/change-event.sh`) |

What leaves the VM (see `otelcol-config-extras.yml`):

- **traces → Whawit** tail-sampled: every trace with an error span or slower than 2 s, plus 5 % of the rest.
- **logs → Whawit and Cloud Logging** (`logName=projects/whawit/logs/astronomy-shop`, resource `generic_task`, `service.*` attributes as labels).
- **metrics → Whawit**: only what services emit over OTLP plus span metrics. Docker/host/nginx/redis/postgres scrapes stay in the local Prometheus (Cloud Monitoring custom metrics are billed by volume, so none go to GCP).
- Every Whawit-bound batch is also appended to `/recordings/*.jsonl`. That is the raw material for golden cases: the recording is exactly what Whawit saw.

## Operating the VM

```bash
whawit/vm.sh status | start | stop
whawit/vm.sh tunnel            # then http://localhost:8080  (/grafana, /jaeger/ui, /feature, /loadgen)
whawit/vm.sh ps                # docker ps
whawit/vm.sh logs 100          # startup-script journal
whawit/vm.sh deploy            # pull main, make start, report a change event to Whawit
whawit/vm.sh ssh "sudo docker logs --tail 50 otel-collector"
```

## Scenarios

Failures are flagd feature flags. `whawit/scenarios.sh` flips them on the VM (no restart; flagd
re-reads the file). Percentage flags need a variant.

```bash
whawit/scenarios.sh list
whawit/scenarios.sh on paymentFailure 25%
whawit/scenarios.sh on productCatalogFailure
whawit/scenarios.sh status
whawit/scenarios.sh off paymentFailure
whawit/scenarios.sh reset          # PANIC BUTTON: everything off
```

| Flag | Culprit | What Whawit should see |
|---|---|---|
| `paymentFailure` (10%…100%) | payment (JS) | checkout `PlaceOrder` errors, `charge` failures in payment logs/spans |
| `paymentUnreachable` | checkout (Go) config | checkout cannot reach payment: connection errors, every order fails |
| `productCatalogFailure` | product-catalog (Go) | `GetProduct` fails for product `OLJCESPC7Z` only; frontend 500s on that product page |
| `cartFailure` (10%…100%) | cart (.NET) | `EmptyCart` errors after checkout |
| `recommendationCacheFailure` | recommendation (Python) | memory growth, slow `ListRecommendations`, eventual OOM restart |
| `emailMemoryLeak` (1x…10000x) | email (Ruby) | memory growth per confirmation email |
| `adFailure` / `adHighCpu` / `adManualGc` | ad (Java) | `GetAds` errors / CPU throttling / GC pauses |
| `kafkaQueueProblems` | kafka + accounting/fraud-detection | consumer lag spike, delayed order processing |
| `loadGeneratorFloodHomepage` | load-generator | traffic flood on frontend, latency everywhere |
| `imageSlowLoad` (5sec/10sec) | frontend-proxy (Envoy fault) | slow image loads, page latency |
| `intlShippingSlowdown` (5sec/10sec) | shipping (Rust) | slow quotes for international addresses |
| `failedReadinessProbe` | cart | Kubernetes only; no effect on compose |

To make a scenario look like a **release** (a real commit Whawit can open): edit
`src/flagd/demo.flagd.json` on your laptop, commit, push, then `whawit/vm.sh deploy`. The VM
resets to `origin/main`, restarts, and posts the commit as a deployment change event.

## Verifying ingest

- Collector health: `whawit/vm.sh ssh "sudo docker logs --tail 100 otel-collector"` — look for
  `otlphttp/whawit` export errors (401 = bad key, 400 = payload, 403 = project access).
- Cloud Logging: `gcloud logging read 'logName="projects/whawit/logs/astronomy-shop"' --project=whawit --limit=5 --freshness=10m`.
- Whawit: telemetry db `whawit-telemetry-sandbox` collections `traces` / `logs` / `metrics`, and the
  Whawit Collector integration's `metadata.services` list under the project.

## Not done yet

- No monitor is active on the project by default; create/unpause one when rehearsing (each on-call
  cycle costs hundreds of thousands of tokens).
- The GCP path (`GCP Astronomy Shop`) is wired but its scope was set before the first entries
  landed; check the resource type/labels of real entries and tighten it.
- Golden-dataset recorder/labels and the replayer live in the Whawit monorepo (spec
  `docs/specs/demo-microservices-golden-dataset/`), not here.
