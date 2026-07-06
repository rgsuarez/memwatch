# Toolchain probe gate: pinned evidence

Every assumption the adjudicator makes about its runtime, verified live on
the deployment machine before the lifecycle glue was built. Re-run this
gate when the llama.cpp build or the Hammerspoon runtime changes.

## Inference runtime

- `llama-server` version: **9870 (2d973636e)**, built with AppleClang 21.0
  for Darwin arm64, installed via Homebrew (`brew install llama.cpp`).
- Binary path on this machine: `/opt/homebrew/bin/llama-server` (the glue
  resolves at runtime: `brew --prefix llama.cpp`, /opt/homebrew/bin,
  /usr/local/bin, then PATH).
- `--api-key KEY` supported (multiple keys, and `--api-key-file`); an
  unauthenticated request against a keyed server returns **HTTP 401**
  (verified live).
- `/health` returns `{"status":"ok"}` when the model is loaded and serving.

## Constrained decoding (the load-bearing finding)

`POST /v1/chat/completions` enforces a JSON-schema grammar ONLY through
the OpenAI-nested response_format shape:

```json
{"response_format": {"type": "json_schema",
  "json_schema": {"name": "verdict", "strict": true, "schema": { ... }}}}
```

The flat `{"type": "json_schema", "schema": {...}}` variant is SILENTLY
ACCEPTED AND IGNORED on this build: the reply came back unconstrained (the
230M model echoed the prompt's format template, `"action":
"wait|freeze|terminate"`, with extra non-schema keys, both impossible
under an enforced grammar). `buildRequestBody` pins the nested shape;
`test_core.lua` pins the shape in the request body.

With the nested shape, the same request returned exactly the four schema
keys with `action` and `process_class` drawn from their enums (verified
via the production prompt builder, serializer, parser, and validator
end-to-end).

## Warm performance (230M Q4_K_M dev model, this machine)

- Prompt eval ~1067 tok/s (539-token adjudication prompt in ~505 ms).
- Decode ~404 tok/s.
- Full production round-trip (curl wall time, warm server): **~0.61 s**.

## Hammerspoon runtime

- `hs.http.asyncPost`, `hs.json.decode`, `hs.json.encode`, `hs.task.new`
  all present (type `function`) in Hammerspoon 1.1.1.

## Artifact registry

- Dev model `LFM2.5-230M-Q4_K_M.gguf`: 153,406,304 bytes, sha256
  `7bbd90384d3deffe4c646ec9643b212802d32d4ce417c90a1ec9282100650062`,
  pinned in `scripts/models.tsv` (fetched via its registry row).
- All eight registry resolve URLs verified HTTP 200 before pinning.
- License text (`licenses/LFM-Open-License-v1.0.txt`, 71 lines) fetched
  from the model repo; sha256 pinned per registry row.
- Ephemeral-port spawn + listener-pid ownership check verified: `lsof
  -iTCP:<port> -sTCP:LISTEN -t` returned exactly the spawned child pid.
