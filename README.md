# Running Cloudflare's clef-flash on Windows with an Intel Arc GPU

A practical guide to running [Cloudflare's clef-flash](https://blog.cloudflare.com/clef-decision-models/)
decision model locally on a Windows PC with an Intel Arc discrete GPU
(verified approach for an Arc A750 with 8 GB VRAM).

## What clef-flash is (read this first)

clef-flash is a **decision model, not a chat model**. Cloudflare released it on
October 1, 2026 under Apache 2.0, with weights on Hugging Face. You feed it a
*state* (text, JSON, images) plus up to 64 *typed questions* — yes/no, multiple
choice, or scored rubrics — and it returns a probability for every allowed
answer in a single forward pass. It never generates text.

Good uses: ticket triage, alert routing, intent classification, a cheap gate in
front of an expensive LLM call. If you wanted something to chat with, this is
the wrong model.

- 9B parameters, built on a Qwen3.5-9B backbone with a custom scoring head
- 64k token context window (you won't need most of it — see below)
- Also on Cloudflare Workers AI for $0.09 per million input tokens if you'd
  rather call an API than run it yourself

The bigger sibling, **Clef (27B)**, needs ~16 GB even quantized — it does not
fit an 8 GB card. This guide covers clef-flash only.

## Will it fit my GPU?

| Variant | Size | Fits 8 GB Arc? |
|---|---|---|
| BF16 (full precision) | ~18 GB | No |
| Q8_0 | ~9.6 GB | No (no room for KV cache) |
| **Q4_K_M** | **~5.8 GB** | **Yes, with context capped** |

The community GGUF quant `ggml-org/Clef-Flash-GGUF` (`Q4_K_M`) is 5.8 GB,
leaving room for the KV cache as long as you cap the context window
(`-c 4096`). Decision requests are short by nature, so you lose nothing.

## Prerequisites

- Windows 10/11 64-bit
- Intel Arc GPU driver (from Intel's Download Center, or the Intel Driver &
  Support Assistant — you likely already have this)
- A recent [llama.cpp](https://github.com/ggml-org/llama.cpp) build. Clef
  support (the `/v1/systemone` endpoint) only landed in early October 2026, so
  **use the latest release or a fresh master build** — anything older won't
  have it.

## Path A — prebuilt Vulkan binary (recommended, ~15 minutes, no build)

This is the fastest way to get running. Someone has already verified the
prebuilt Vulkan build serving clef-flash Q4_K_M with correct, well-calibrated
decision output.

1. Go to [llama.cpp releases](https://github.com/ggml-org/llama.cpp/releases)
   and download the newest `llama-*-bin-win-vulkan-x64.zip`.
2. Unzip it somewhere, e.g. `C:\llama.cpp`.
3. Open a terminal (PowerShell or cmd) in that folder and start the server:

```bat
llama-server -hf ggml-org/Clef-Flash-GGUF:Q4_K_M -c 4096 -ngl 99
```

What the flags do:
- `-hf ggml-org/Clef-Flash-GGUF:Q4_K_M` — downloads the quant directly from
  Hugging Face on first run (no manual download needed)
- `-c 4096` — caps context at 4k tokens so the KV cache fits in 8 GB VRAM
- `-ngl 99` — offloads all model layers to the GPU

4. Test it (see [Making requests](#making-requests) below).

No Intel toolchain, no compiler, no multi-GB SDK. For a decision model — one
forward pass per request — Vulkan performance on Arc is fine.

## Path B — prebuilt SYCL binary (middle ground, no build, no SDK install)

llama.cpp also ships `llama-*-bin-win-sycl-x64.zip` releases that bundle the
required oneAPI DLLs. Same steps as Path A, just a different zip. This gets
you the SYCL backend (best performance on Intel GPUs) without installing the
oneAPI Toolkit or compiling anything. Same freshness rule applies: the release
must be new enough to include the `/v1/systemone` endpoint.

## Path C — build SYCL from source (best performance, most setup)

Follow the official guide: [llama.cpp for SYCL](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/SYCL.md).
Summary for Windows:

1. Install the Intel Arc GPU driver if you don't have it.
2. Install the [Intel oneAPI Toolkit for Windows](https://www.intel.com/content/www/us/en/developer/tools/oneapi/base-toolkit-download.html)
   (select Windows on the download page). This is the tedious part — a
   multi-GB download. Keep the default install path
   (`C:\Program Files (x86)\Intel\oneAPI`).
3. Install CMake for Windows (also available through the Visual Studio
   installer).
4. Open the **"Intel oneAPI command prompt for Intel 64 for Visual Studio
   2022"** app (search "oneAPI" in the Start menu).
5. In that prompt:

```bat
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
.\examples\sycl\win-build-sycl.bat
```

6. Run the server from the oneAPI prompt:

```bat
set ONEAPI_DEVICE_SELECTOR=level_zero:0
build\bin\llama-server.exe -hf ggml-org/Clef-Flash-GGUF:Q4_K_M -c 4096 -ngl 99
```

Verify your GPU is detected first with `build\bin\llama-ls-sycl-device.exe` —
you should see your Arc listed as a `level_zero` GPU device.

## Making requests

The server exposes the decision endpoint at `http://localhost:8080/v1/systemone`.
It takes a `state` and a set of typed questions. In PowerShell, `curl.exe`
works:

```bat
curl.exe http://localhost:8080/v1/systemone -H "Content-Type: application/json" -d "{\"model\":\"clef-flash\",\"state\":\"Disk on db-02 is at 97% and growing about 1% an hour.\",\"questions\":{\"page_oncall\":{\"type\":\"noul\",\"instructions\":\"Should someone be paged right now?\"},\"severity\":{\"type\":\"score\",\"instructions\":\"How severe is this?\",\"criteria\":[\"Info\",\"Minor\",\"Major\",\"Critical\"]}}}"
```

Question types:
- `noul` — yes/no ("should someone be paged?")
- multiple choice — pick one named option
- `score` — rate on a rubric you define via `criteria`

A healthy response returns probabilities for each option and
`output_tokens: 0` (nothing is generated — that's the point). If the numbers
are finite and roughly calibrated, it's working.

## Gotchas

- **Ollama works on Windows from v0.40.1 up.** Older releases fail every
  request for clef-flash (9B Q8_0) with `Clef: non-finite logit`
  ([ollama/ollama#18769](https://github.com/ollama/ollama/issues/18769)).
  (The bug only bites when the clef head's file offset passes 2 GiB, so
  clef:27b Q4_K_M worked on `/v1/systemone` all along.)
  Root cause: the Windows runner's libc++ truncated the clef head's weight-file
  seek to 32 bits, so the head loaded backbone bytes (full of NaN/inf patterns)
  as its weights. Fixed in
  [ollama/ollama#18777](https://github.com/ollama/ollama/pull/18777), shipped in
  Ollama v0.40.1 — update before trying the Ollama route. One residual:
  `OLLAMA_LLM_LIBRARY=cpu`'s separate `Clef: cannot open model` error is not
  covered by that fix. (Upstream llama.cpp remains the safe choice if you'd
  rather not depend on the fix.)
- **Text input only (for now).** The model itself accepts images, but
  llama.cpp's clef support doesn't handle image input yet.
- **Cap your context.** The 64k window is real, but 64k of KV cache will not
  fit in 8 GB VRAM. `-c 4096` (or 8192) is plenty for decision workloads.
- **Fresh builds only.** Anything from before October 2026 predates the
  `/v1/systemone` endpoint.
- **This moves fast.** Clef launched October 1, 2026; expect the local
  tooling to keep changing week to week. When in doubt, check the model card
  and the llama.cpp docs linked below.

## Links

- [Cloudflare announcement: "Introducing Clef"](https://blog.cloudflare.com/clef-decision-models/)
- [llama.cpp](https://github.com/ggml-org/llama.cpp) / [releases](https://github.com/ggml-org/llama.cpp/releases)
- [llama.cpp SYCL backend docs (Intel GPU)](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/SYCL.md)
- [Intel oneAPI Toolkit download](https://www.intel.com/content/www/us/en/developer/tools/oneapi/base-toolkit-download.html)
- Model weights: `Cloudflare/clef-flash` and the GGUF quant
  `ggml-org/Clef-Flash-GGUF` on [Hugging Face](https://huggingface.co/)
