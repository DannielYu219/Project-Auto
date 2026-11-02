# Splash 1.5.0 external engine for Velum

## Payload and trust

`package/` is a schema-v2 external engine, id `splash`, version `1.5.0-velum.2`, CPython ABI `cp312`, macOS arm64 26.4+, Apple M3+. It includes the official Splash native C++/Metal binary, both metallibs, unmodified official `install/` and `server/` Python modules, upstream licenses/notices, and independently installed **exact official pinned cp312/abi3 wheels**. There is **no Python executable, pip, MLX package, PyTorch, or model weight in the engine archive**. Safetensors/GGUF loading and GPU inference are handled by Splash's native engine, not MLX.

The official release archive SHA256 is `1ddc28bf7bfda8833859a913d7072e2aac9072addb9eb5664f3bf1a83a8d6ee2` (a 64-digit SHA256, not SHA1). Provenance and dependency lock are inside the payload. Native files receive development ad-hoc signatures before every-file hashing. The archive is **not Developer-ID signed or notarized**, and the importer must require its explicit development opt-in. Never treat the hash manifest alone as publisher authentication.

`build_package.py` signs and strictly verifies every Mach-O, hashes every regular payload file except the top-level manifest, and creates a single-root development archive plus checksum/report. It only writes within this directory. Do not run build tools against the shared Python base. Copy the sealed base for testing; always execute it with `-I -B`.

## Launch contract

Launch the shared clean Python base, not a bundled or system interpreter:

```sh
/path/to/python-base/python/bin/python3.12 -I -B /path/to/splash/service/server.py --port 0
```

Set `VELUM_RUNTIME_TOKEN` to a random secret of at least 24 characters, `VELUM_RUNTIME_PARENT_PID` to the immediate launcher's PID, and `VELUM_MODELS_DIR` to a writable external model directory. The wrapper only imports its own explicitly authorized site-packages and official module roots; isolated mode ignores PYTHONPATH. It binds **127.0.0.1 only**, with OS-selected port 0, and first writes exactly one machine-readable stdout JSON line:

```json
{"event":"ready","protocol":"velum.local-ai.v1","host":"127.0.0.1","port":12345,"pid":123,"runtime_id":"splash","version":"1.5.0-velum.2"}
```

The reported PID is the wrapper PID, not the native subprocess. Diagnostics go to stderr. Ready means authenticated control-plane ready and native `device-check` passed; **it does not mean a model is loaded**. Startup never downloads a model. Parent disappearance is checked every 250 ms; shutdown cancels preparation processes and terminates the official Python server and native process group. The isolated bootstrap has its own parent watcher to avoid orphaned native children even if the wrapper is killed.

## HTTP API

Every endpoint requires `Authorization: Bearer <VELUM_RUNTIME_TOKEN>`. Missing/invalid/duplicate credentials return 401. Browser Origin headers are rejected. No externally supplied base URL is accepted or exposed.

| Method / endpoint | Body / behavior |
| --- | --- |
| GET `/health` | `status`, protocol/runtime_id/version/pid, `loaded` map, active request, jobs, native device check, capabilities, pinned catalog. No model is necessary. |
| GET `/v1/models` | OpenAI `{object:"list",data:[...]}` of installed prepared descriptors, empty initially. |
| POST `/control/import` | Managed local `{target,draft,mmproj:null,capability:"chat",display_name}`. Synchronous200 prepared descriptor, no load/download; details below. |
| POST `/control/download` | Explicit `{repo,revision,capability:"chat",variant:"PQ2_0",max_download_bytes:15000000000}`. Returns 202 asynchronous job, no automatic load. Target and required compatible draft are prepared and fully verified by official installer. |
| GET `/control/jobs/<job_id>` | Job status queued/downloading/verifying/completed/failed/cancelled, downloaded_bytes, errors. |
| POST `/control/load` | `{model:<id or repo or selection>,capability:"chat"}`. Loads **only installed/verified** assemblies, starts official `server.server` through shared Python with `-I -B`, which starts `engine/splash serve-native`. No networking/download on this path. Returns installed descriptor after native ready. |
| POST `/v1/chat/completions` | OpenAI chat body, stream false or SSE true. Lazy-loads an explicitly selected installed model, never downloads it. Official OpenAI response forwarded; request model id is translated to official selection. |
| POST `/control/unload` | Optional capability chat; stops official native frontend/model, keeps wrapper ready. |
| POST `/control/cancel` | Stops active upstream and preparation processes; next chat must load model again. Returns cancelling. |
| POST `/control/shutdown` | Returns stopping, cancels all children, exits wrapper. |
| POST `/v1/embeddings` | **422**: unsupported; never advertised as a capability. |

Concurrent load/unload/chat requests return 409 busy. Unknown endpoints return404; an uninstalled model returns404 with explicit preparation instructions; unsupported catalog/revision returns422; too-small budget returns413. Client disconnect during generation closes the internal request to cancel native work. A load cancelled/disconnected during startup terminates its complete native process group.

## Managed local model groups (velum.2)

`POST /control/import` requires the same Bearer authentication and a JSON object:

```json
{"target":"/managed/Models/splash-local/id/target/model-00002-of-00003.gguf","draft":"/managed/Models/splash-local/id/draft","mmproj":null,"capability":"chat","display_name":"My Local Bonsai"}
```

`target` and `draft` are required. `target` accepts a single GGUF file, **any part** of a split GGUF (all other parts must lie beside it), or a directory containing one whole/split GGUF target or a compatible safetensors model. Official `install.local.prepare_local_model` discovers and validates the complete split; the adapter does not concatenate or guess shards. `draft` accepts a complete DFlash2 directory, or its `config.json`/one `.safetensors` file; file input is normalized to the complete containing checkpoint directory. A standalone draft shard without config and all indexed shards is refused. `mmproj` is optional/null for text-only GGUF; if present it must be a compatible GGUF projector file. `capability` defaults to `chat` and rejects anything else. `display_name` defaults to target stem and accepts1-120 printable characters.

All paths must be absolute lexical descendants of the configured `VELUM_MODELS_DIR`; `..` is forbidden. Resolved paths must remain inside that same managed root. Files and discovered GGUF neighbors are validated; directory imports and drafts are recursively checked to reject nested symlink escapes, directory symlinks and special files. The helper repeats validation immediately before official preparation. No other root is authorized. The managed store is assumed to be owned and modified by the authenticated App; like the official path-based API, this is not a filesystem sandbox against concurrent malicious replacement of owned files.

Success returns200 with the installed model descriptor, including `id=local/<slug>@<12-character assembly hash>`, `repo` and `selection=local/<slug>-<hash>`,40-hex `revision`, relative prepared `path`, `capability`, `created`, `display_name`, `source=local`, original `target`/normalized `draft`/`mmproj`, `family`, `vision`, `object`, `owned_by`, `status`. Reimporting unchanged inputs/name is idempotent. Existing catalog records are preserved. The generated `selection` is a legal official server OWNER/REPO identifier; the actual prepared assembly path is separately passed as MODEL_DIRECTORY. `/v1/models`, `/control/load` and both chat modes accept the new id.

Errors:400 invalid fields/relative path/`..`;401 missing/wrong credentials;403 root/symlink escape;404 missing target/draft/mmproj;409 runtime busy or cancelled;422 invalid checkpoint/projector or unsupported native family/capability;504 preparation exceeds600s. Error body remains `{error:{message,type}}`. Import is serialized with load/unload/chat. Cancellation/parent exit kills the isolated preparation process group.

Only the official stable `prepare_local_model(target,draft,mmproj=...,models_dir=MODELS)` prepares files. The isolated helper sets offline modes and denies socket connect/DNS with a Python audit hook, does not import repository code, and never invokes pip/download helpers. Actual local test used preexisting hardlinks (no extra11GB copy), a dead proxy and offline environment. See `local-import-report.json` and `local-import.stderr.log`: import4.929s, real native load11.262s, exact `LOCAL_SPLASH_OK`, SSE `Hello`/`[DONE]`, unload/shutdown, rejection cases and draft-file idempotency passed. No compatible mmproj was present: successful vision inference was not tested; malformed mmproj was rejected422. `split-discovery-report.json` verifies official discovery from the middle of3 named parts and missing-part refusal; actual split-weight inference was not run because the existing Bonsai weight is one GGUF.

## Explicit bounded model selection

The first tested catalog entry is the smallest **officially suggested** Ternary-Bonsai-2 target variant:

- Target `prism-ml/Ternary-Bonsai-2-27B-gguf:PQ2_0`, revision `94dd51cdbbec5309ed8b76a12f3268bc4fdceb93`, GGUF 7,206,168,928 bytes.
- Compatible family draft `incoai/Qwen3.8-27B-DFlash2`, revision `015e795645c74b1a0eeef3b570031fb62e769bc5`, safetensors3,848,817,896 bytes.
- Combined weights11,054,986,824 bytes, plus small metadata; text-only preparation deliberately skips the optional vision projector. Official suggestion recommends24GB Mac memory; validation host has64GB.
- Runtime id `prism-ml/Ternary-Bonsai-2-27B-gguf:PQ2_0@94dd51cdbbec5309ed8b76a12f3268bc4fdceb93`.

Catalog scope is deliberately conservative: arbitrary Hugging Face or small MLX models are not assumed compatible with Splash. New entries need native family checks and matching pinned DFlash2 drafts. Models stay external in `Models/` and are **excluded from the54MB engine archive**. Both sources and their file hashes are recorded by the official assembly. A completed installation is fully verified before registry publication.

The adapter honors explicit `VELUM_DOWNLOAD_PROXY` only when configured by the broker; no development proxy is baked into the payload. Development downloads here used explicit `http://127.0.0.1:7890`; all internal loopback calls use direct HTTP. The isolated bootstrap recovers a missing HEAD Content-Length from the exact immutable Hub repository metadata for proxies that strip it, without changing revision or trusting a partial response. The development-only `download_smoke_models.py` alternatively downloads pinned assets with curl and verifies their Git/LFS object hashes before cache publication; it is not shipped or called at user runtime.

## Validation evidence

`adapter-smoke.json` covers control readiness, native signed device-check, unauthorized401, unsupported models/missing prepared model, budget rejection, no automatic download, embeddings422, unload/cancel/shutdown, and launcher-parent exit cancellation. `adapter-smoke.stderr.log` contains diagnostics.

`test_inference.py` uses only the explicit existing pinned assets, performs official offline assembly preparation through the real control/download endpoint, loads the actual C++/Metal native process, requests nonstream and SSE inference, and unloads/shuts down. Its report is created only from actual responses; failed or missing inference must not be represented as successful. Final report and package digests are in `inference-report.json` and `package-report.json` when present.

Final results on this host: actual target/draft preparation completed; warm native load8.962s (first cold compilation56.392s); nonstream returned exactly `SPLASH_OK`; SSE returned `Hello` then `[DONE]`; unload/shutdown succeeded. Disk cache is deliberately disabled by the wrapper (`--max-cache-disk 0`) to avoid an implicit32GiB SSD cache. The native-parent test loaded the real model, exited the launcher, and verified wrapper, official Python frontend, and native engine all terminated. The velum.1 inference/parent checks passed5457 hashes; velum.2 relocation passed all5458 hashes and57 strict ad-hoc signature verifications, authenticated startup/shutdown, and no payload bytecode mutations.

Final velum.2 development archive:54,303,722 bytes. Archive SHA256 `468acdb08998e2736585bb9e555daeddfb2fdcdb4bb0e2915a147036849b47a3`; manifest SHA256 `dece7c665c8e62938e15fb2dd77d4037cb2e4a724de828d42791886acac5aed0`. These refer to the exact final sealed payload, not model assets. The previous velum.1 archive is preserved alongside it.

Upstream: https://github.com/incoai/splash/releases/tag/1.5.0 .
