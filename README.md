<div id="top"></div>

<div align="center">

# Harness

Lightweight D agent runtime with persisted actor graphs, Mixr routing, and a local desk UI.

<a href="https://github.com/dev-centr/harness/graphs/contributors"><img src="https://img.shields.io/github/contributors/dev-centr/harness" alt="Contributors"></a>
<a href="https://github.com/dev-centr/harness/network/members"><img src="https://img.shields.io/github/forks/dev-centr/harness" alt="Forks"></a>
<a href="https://github.com/dev-centr/harness/stargazers"><img src="https://img.shields.io/github/stars/dev-centr/harness" alt="Stars"></a>
<a href="https://github.com/dev-centr/harness/issues"><img src="https://img.shields.io/github/issues/dev-centr/harness" alt="Issues"></a>

[Explore the docs »](https://docs.devcentr.org/agent-rules/agent-harness.html)

</div>

Harness is **D only**, enables **tgc** (thread-local GC) by default, persists its node graph on disk, and uses **Mixr** for model routing.

| Phase | Ships |
| --- | --- |
| **v0** | `graph.json`, per-node `meta.json` + `chat.jsonl`, orchestrator metathread, CLI |
| **v0.5** | Mixr on-device + suppress lists; `/api/health`, OpenAI-compat stub, `/api/provider/*` for t3code |
| **v1** | Mixr router, wait-graph (`warn` default), HTTP desk (`harness serve`) |
| **v2** | Temporal layout engine — scrubber, fade, heatmap, scoped bookmarks |
| **desk PM** | Status colors for `awaiting_user` / failed; **Mark completed** + **Archive** (`POST /api/hide`) |

## Contents

- [Changelog](#changelog)
- [Build](#build)
- [Quick start](#quick-start)
- [Disk layout](#disk-layout)
- [Harness configuration](#harness-configuration)
- [Architecture](#architecture)
- [Built with](#built-with)

## Changelog

See [CHANGELOG.adoc](CHANGELOG.adoc).

<p align="right">(<a href="#top">back to top</a>)</p>

## Build

Requires [DUB](https://dub.pm/) and LDC/DMD. Thread-local GC via dependency on [`dlang-supplemental/tgc`](../../dlang-supplemental/tgc) (`Tgc_default` → `--DRT-gcopt=gc:tgc` embedded in the binary).

```powershell
cd $env:code\github.com\dev-centr\harness
dub build
dub test
```

<p align="right">(<a href="#top">back to top</a>)</p>

## Quick start

```powershell
.\harness.exe init .\my-chat
.\harness.exe spawn .\my-chat --parent=coordinator --type=task --title=docs-sync
.\harness.exe serve .\my-chat --port=8765
```

Open http://127.0.0.1:8765 for the desk UI.

<p align="right">(<a href="#top">back to top</a>)</p>

## Disk layout

Matches [actor-model-agentic-ui](https://docs.devcentr.org/agent-rules/actor-model-agentic-ui.html):

```
$CHAT_ROOT/
  graph.json
  orchestrator/meta.jsonl
  nodes/{id}/meta.json
  nodes/{id}/chat.jsonl
  timeline/bookmarks.jsonl
```

<p align="right">(<a href="#top">back to top</a>)</p>

## Harness configuration

Set `HARNESS_NAME = harness` in `$CODE_ROOT/harness.md`.

<p align="right">(<a href="#top">back to top</a>)</p>

## Architecture

- **Long-lived:** `harness serve` — supervisor + HTTP desk (future: `harnessd` RPC for thin CLI clients).
- **One-shot:** CLI subcommands touch disk directly (git-shaped); no Python, no embedded interpreter per invoke.
- **tgc:** per-thread heaps; collections do not stop-the-world sibling threads — fits actor swarms + `@nogc` workers.
- **Discovery vs routing:** [Open Provider Registry / UniProvider](https://github.com/dev-centr/uniprovider) finds endpoints; **Mixr** chooses models. Prefer OPR manifests over hard-coding a single local runner brand.

<p align="right">(<a href="#top">back to top</a>)</p>

## Built with

**Runtime**

- [D](https://dlang.org/) — native implementation
- [tgc](https://github.com/dlang-supplemental/tgc) — thread-local garbage collection

**Interface**

- Browser-native HTML, CSS, and JavaScript — local desk UI

<p align="right">(<a href="#top">back to top</a>)</p>
