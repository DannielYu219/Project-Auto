# Split Python base and external engines

This directory implements the split architecture without modifying `Runtime/local-ai`, App sources, or the Xcode project. The App embeds **only `python-base/`**. The MLX and custom packages remain outside the App. Models remain separately managed data.

## Artifacts

| Artifact | Directory | Archive | SHA-256 |
| --- | --- | --- | --- |
| Clean standalone CPython 3.12.16 | `python-base/` | `velum-python-3.12.16-split.1-macos-arm64.tar.gz` | `3cdacb2a8cca1f85e069bff3f357d8dbba62c0856a74823d12aa7d92b01df8a8` |
| External MLX engine | `engines/mlx/` | `velum-engine-mlx-2026.11.02-split.1-macos-arm64.tar.gz` | `f7d0be6491b6ad88e48f1bac5656afe554bfc274b065bc6d7259f9a56a273672` |
| Custom stdlib sample | `engines/custom-echo/` | `velum-engine-custom-echo-2026.11.02-split.1-macos-arm64.tar.gz` | `3bf07fca3017823d16bb889e5ee05598105d7208eacbec071d870df6a1d61a1d` |

`evidence/packages.json` records exact byte sizes, archive digests, manifest digests and native/file counts. Archives each contain one named root directory. Extract that root as the base or engine root; do not combine engine contents into the Python directory.

## App base integration

Embed the entire `python-base` directory preserving its relative layout, executable bits and symlinks. Its root contains `runtime.json`, `provenance.json`, `licenses/`, and `python/`. The canonical executable is **`python/bin/python3.12`**; `python/bin/python3` and `python/bin/python` are relative symlinks to it. Supplying a tar instead is possible, but the App must extract and validate the base before launching. Embedding the prepared directory avoids an initial extraction step.

Base manifest:

```json
{
  "schema_version": 2,
  "id": "velum-python",
  "kind": "python-base",
  "version": "3.12.16-split.1",
  "platform": "macos",
  "architecture": "arm64",
  "minimum_macos": "26.0",
  "python": {
    "version": "3.12.16",
    "abi": "cp312",
    "executable": "python/bin/python3.12"
  }
}
```

The actual manifest additionally contains complete `files`, `symlinks`, and `signing` records described below. Its SHA-256 is `4e324837965ee84bee24ca6a29479476c6f0dfb1aa9833630a1a6fee0ffbd766`.

The base comes directly from the existing python-build-standalone 20261026 install-only-stripped archive, whose original SHA-256 is `353d5f1b4fd2715e7053f12f068435d5bbad16b91e057006b5d01e0925709a7e`. It contains CPython and its standalone standard-library/native dependencies, including Tcl/Tk supplied upstream. It contains **no site-packages directory**, MLX, NumPy, pip, ensurepip, setuptools, wheel, headers, pkg-config data, interpreter config build directories, static archives, build console scripts, or bytecode caches. The CPython license remains in its standard-library location and beneath `licenses/`. Because the stripped archive omits native dependency notices, `licenses/python-build-standalone/` additionally includes all 21 upstream license files from the pinned 20261026 source tree, including OpenSSL, Tcl, SQLite, libffi, bzip2, ncurses, zlib and the complete upstream CPython notices. `licenses/upstream-provenance.json` records their source URLs, upstream Git blob identifiers and SHA-256 digests.

The prepared base has 954 regular payload files, two symlinks and 11 ad hoc signed Mach-O binaries. Signing or rewriting these binaries after generating the manifest changes their digests. Validate the embedded copy after the App signing phase; a release build that re-signs nested code must regenerate the matching manifest before sealing the App.

## External engine contract

Each package root contains **`runtime.json`**, **`service/server.py`**, and optionally **`site-packages/`**. No interpreter or base standard library is present. The package root is the unit of import, atomic installation, verification, rollback and deletion. Install packages outside the App.

MLX manifest identity:

```json
{
  "schema_version": 2,
  "id": "mlx",
  "kind": "python",
  "version": "2026.11.02-split.1",
  "platform": "macos",
  "architecture": "arm64",
  "minimum_macos": "26.0",
  "python_abi": "cp312",
  "entrypoint": "service/server.py",
  "capabilities": ["chat", "embeddings", "download"],
  "adapter": {
    "protocol": "velum.local-ai.v1",
    "host": "127.0.0.1",
    "port": 0,
    "auth_env": "VELUM_RUNTIME_TOKEN",
    "models_env": "VELUM_MODELS_DIR",
    "parent_pid_env": "VELUM_RUNTIME_PARENT_PID"
  },
  "tested_python_base_manifest_sha256": "4e324837965ee84bee24ca6a29479476c6f0dfb1aa9833630a1a6fee0ffbd766"
}
```

The actual manifest also has:

- `files`: dictionary mapping every regular payload-relative path to its SHA-256, excluding the top-level `runtime.json` itself.
- `symlinks`: dictionary mapping every symlink-relative path to its exact relative link target. All targets must remain inside the package root.
- `signing`: `{ "policy": "development-adhoc", "notarized": false, "mach_o_files": [ ... ] }`. Every native file in this list was signed and strictly verified before computing payload hashes.

The MLX engine has 10,537 regular payload files, no symlinks and 273 signed Mach-O files. The existing wheel/source provenance and hashed requirements lock are retained. Its manifest SHA-256 is `4008f8e1d85d44c86a406039be82089b77b07454be983053f57c32280fc00a35`. The tested base digest is compatibility evidence, not a requirement that future ABI-compatible clean base builds have identical bytes.

These are development artifacts. Native ad hoc signatures and hashes do not establish publisher authenticity. The manager must require explicit development opt-in. There is no detached release signature in these packages. A future release can add trusted detached metadata signatures, Developer ID signatures and notarization; it must regenerate manifests and package digests accordingly.

## Launch and service behavior

Execute the embedded base directly, using argument arrays:

```text
<baseRoot>/python/bin/python3.12
-I
-B
<externalEngineRoot>/service/server.py
--port
0
```

The App passes a fresh `VELUM_RUNTIME_TOKEN` of at least 24 characters, the absolute writable external model directory in `VELUM_MODELS_DIR`, and its actual launcher process ID as `VELUM_RUNTIME_PARENT_PID`. The engine monitors parent death and shuts down automatically. It can run from any working directory. `VELUM_MODEL_ID` may be supplied by the broker, but selection occurs through an explicit model in inference requests or `/control/load`; this adapter does not implicitly preload the environment-selected model.

`-I` ignores `PYTHONPATH`, `PYTHONHOME`, user site and the current directory. The service bootstrap explicitly inserts only `Path(__file__).resolve().parents[1] / "site-packages"` into `sys.path`. It does not use `site.addsitedir`, execute `.pth` files, invoke pip, install anything globally or execute a shell launcher. `-B` prevents runtime bytecode writes. Model snapshot loading disables repository Python with `trust_remote_code=False`.

Only the first stdout line is machine-readable readiness:

```json
{"event":"ready","protocol":"velum.local-ai.v1","host":"127.0.0.1","port":12345,"pid":123,"runtime_id":"mlx","version":"2026.11.02-split.1"}
```

Diagnostics go to stderr. Every endpoint requires `Authorization: Bearer <token>`. The service binds only IPv4 loopback. The token is never returned in readiness. Existing HTTP endpoints and their request/response semantics are preserved:

| Endpoint | Behavior |
| --- | --- |
| `GET /health` | Identity, loaded model IDs, active work and jobs. |
| `GET /v1/models` | Installed registered models. |
| `POST /v1/chat/completions` | OpenAI normal JSON or SSE; model-supported reasoning/tool deltas. |
| `POST /v1/embeddings` | Float/base64 normalized text embeddings; dimensions 128/256/512/768. |
| `POST /control/load` | `{model,capability}` loads a registered model. |
| `POST /control/unload` | Optional capability or all. |
| `POST /control/cancel` | Cooperatively cancel generation. |
| `POST /control/shutdown` | Stop work and service. |
| `POST /control/download` | Pinned 40-character revision plus repo/capability; returns job. |
| `GET /control/jobs/<job_id>` | Download status. |

No proxy is forced. Downloads use direct connections when proxy settings are absent, or the caller's explicit `VELUM_DOWNLOAD_PROXY` / HTTP(S) proxy settings. Python, packages, model data and all split inference tests reused local assets. The additional dependency license notices were fetched from the pinned upstream source tree explicitly through `http://127.0.0.1:7890`; the inference verification performs offline model loading with all proxy settings removed. Any future build-time fetch for this task must explicitly use the same proxy.

## Custom package sample

`template/service/server.py` is the editable stdlib-only adapter sample. The built `engines/custom-echo/` package follows the same schema, `python_abi`, entrypoint, readiness, bearer-authentication, parent-monitor and shutdown contract. Its identity is `custom-echo`, capabilities are `["chat", "models"]`, and the local model ID is `custom-echo`. It returns deterministic `Echo: ...` content in both normal JSON and SSE. It performs no ML inference. It deliberately has no third-party package dependencies.

For a custom package, copy the template adapter into `service/server.py`, update `RUNTIME_ID` and `VERSION`, add ABI-compatible dependencies to `site-packages` if needed, and generate a complete schema 2 manifest after signing native code. The engine ID and version in readiness must match the manifest. Never ship Python inside a custom engine.

## Verification

`build_split.py` is the reproducible assembly/sealing script using existing local assets. It refuses to overwrite existing output directories. `verify_split.py` extracts all three archives under a new path containing spaces, verifies complete inventories/hashes/symlinks/native signatures, runs the relocated interpreter and engines from `/`, and verifies inventories again after execution. The current successful results are in `evidence/integration.json`.

Actual checks passed:

- Clean CPython 3.12.16, isolated mode, no bytecode, and imports of ssl/sqlite3/ctypes. pip/ensurepip/setuptools/wheel/MLX/NumPy all absent from base.
- External MLX packages imported under `-I -B` despite deliberately invalid `PYTHONPATH` and `PYTHONHOME`.
- Offline Qwen3-0.6B-4bit normal chat returned “Hello! How can I assist you today? What can I help with?”; SSE reached `[DONE]`.
- Offline embeddinggemma-2-4bit returned two 128-dimensional vectors with norms approximately 0.99999999; base64 encoding had the expected 512 bytes per 128-float vector.
- Wrong bearer token returned 401; unload and authenticated shutdown exited successfully.
- Stdlib custom echo normal JSON and SSE passed; SIGTERM exited successfully.
- A chat-to-embedding model switch retained only the embedding model; all previous model references and Metal caches were released before loading the replacement.
- Killing the launcher caused MLX's socket to close in 0.329 seconds and the custom engine in 0.373 seconds; both processes were reaped.
- All sealed hashes and native signatures remained valid after actual inference.

Model snapshot files were reused locally under a separate verification model directory, with a copied registry; no model downloads or old registry writes were performed.
