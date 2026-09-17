<!--
  HAND-MAINTAINED. Nothing generates this page, and nothing may.

  Rules, in force:
    1. Public, non-fork, non-archived repositories only.
    2. Prefer a repository's own documentation site over its GitHub URL.
    3. No private repository names. No account ids, hostnames, tokens, e-mail
       addresses, customer or personal data, or internal roadmap.
    4. Nothing outside this repository is read at build time. This site must
       build from a clean clone of this repository plus PyPI, and nothing else.

  To refresh — by hand, reviewed, and pasted in; NEVER as a build step:
    gh repo list nikolareljin --visibility public --source --no-archived \
      --limit 300 --json name,description,homepageUrl
  Then confirm every link below still returns 200:
    grep -oE 'https://[^)]+' docs/about.md | sort -u | while read -r u; do
      printf '%s  %s\n' "$(curl -sIL -o /dev/null -w '%{http_code}' --max-time 10 "$u")" "$u"
    done
-->

# About

I build small, sharp tools: CI plumbing, shell libraries, device and hardware
utilities, and local-first AI. Everything listed here is public.

!!! tip "Companion library"
    **ci-helpers** is the GitHub Actions side; [**script-helpers**](https://nikolareljin.github.io/script-helpers/)
    is the Bash side. This repository vendors that one for its own scripting,
    and the two share one documentation system — if you are writing the scripts
    that CI runs, you probably want both.

## CI, release and repository tooling

| | |
|---|---|
| [script-helpers](https://nikolareljin.github.io/script-helpers/) | Reusable Bash and PowerShell helper modules — logging, docker, devices, packaging. Runs on macOS bash 3.2. |
| [git-lantern](https://nikolareljin.github.io/git-lantern/) | CLI mapping local and GitHub repositories — branch status, ahead/behind, visibility, releases. |
| [docforge](https://nikolareljin.github.io/docforge/) | Generates developer references and end-user guides from any codebase. |
| [claude-docsmith](https://nikolareljin.github.io/claude-docsmith/) | User and developer documentation from a repository, using Claude or a local model. |
| [git-pulse](https://github.com/nikolareljin/git-pulse) | Self-hosted dashboard analysing repositories for contributor impact, health and code quality. |
| [ci-orchestrator](https://github.com/nikolareljin/ci-orchestrator) | Multi-platform CI/CD orchestration across Jenkins, GitHub Actions, GitLab CI and Bitbucket. |

## Security

| | |
|---|---|
| [leak-lock](https://nikolareljin.github.io/leak-lock/) | VS Code extension finding secrets in git history, verifying live credentials, and rewriting safely. |
| [claude-reposec](https://nikolareljin.github.io/claude-reposec/) | Deep-scans repositories for secrets, PII, vulnerabilities, history leaks and dependency CVEs. |

## Claude Code plugins

| | |
|---|---|
| [claude-plugins](https://nikolareljin.github.io/claude-plugins/) | Plugin marketplace registry. |
| [claude-reelsmith](https://nikolareljin.github.io/claude-reelsmith/) | Batch-finishes video: audio, stabilisation, branding, titles and captions. |

## Local-first AI

| | |
|---|---|
| [local-ai-lab](https://nikolareljin.github.io/local-ai-lab/) | Hands-on course for private local AI — RAG, MCP, LangChain, LangGraph. No Docker required. |
| [ai-runner](https://nikolareljin.github.io/ai-runner/) | Run Ollama models locally with a simple selection UI. |
| [nikos](https://nikolareljin.github.io/nikos/) | Turns Ubuntu 24.04 into a local-first AI workstation in one Ansible run. |
| [ink-mate](https://nikolareljin.github.io/ink-mate/) | Local-first ESP32-S3 e-paper desk companion — voice, FastAPI gateway, Ollama. |
| [finetorch](https://github.com/nikolareljin/finetorch) | Rust-native LLM finetuning — LoRA/QLoRA, datasets, training and eval on one GPU. |
| [shrink-llm](https://github.com/nikolareljin/shrink-llm) | Compressing models for phones: quantisation, pruning, distillation. |

## Devices and hardware

| | |
|---|---|
| [android-device-rescue-kit](https://nikolareljin.github.io/android-device-rescue-kit/) | ADB toolkit for Android dumps, backups, restores and reboot-loop triage. |
| [pharos](https://nikolareljin.github.io/pharos/) | General-purpose Android display and control node for dashboards, telemetry and alerts. |
| [x240-kbd](https://nikolareljin.github.io/x240-kbd/) | ThinkPad X240 keyboard and ClickPad USB HID controller — RP2040, QMK, OpenSCAD. |
| [kiosk-frame](https://nikolareljin.github.io/kiosk-frame/) | 32-bit kiosk photo frame and magic mirror on AntiX, with a web config UI. |
| [iso-forge](https://nikolareljin.github.io/iso-forge/) | Terminal tool for downloading Linux images and writing them to USB. |
| [distrodeck](https://nikolareljin.github.io/distrodeck/) | Maintain, install and upgrade a Debian-based distribution. |
| [kinect-forge](https://github.com/nikolareljin/kinect-forge) | Turns a Kinect v1 into a 3D scanner — capture, reconstruct, measure, export. |
| [ShelfCast](https://github.com/nikolareljin/ShelfCast) | Turns a Raspberry Pi into a touch-first dashboard for a Nook Simple Touch or an old tablet. |

## Applications

| | |
|---|---|
| [orthodox-calendar](https://nikolareljin.github.io/orthodox-calendar/) | Saints, name-days, readings, moon phases and ICS feeds across 17 traditions. |
| [500ad](https://nikolareljin.github.io/500ad/) | Mobile turn-based Byzantine strategy game, 500–1453 AD, on a 24,000-tile Mediterranean map. |
| [PravKal](https://nikolareljin.github.io/PravKal/) | Serbian Orthodox liturgical calendar — a Free Pascal TUI port of the DOS original. |
| [denial-shield](https://nikolareljin.github.io/denial-shield/) | Automated medical denial rebuttal assistant. |
| [scancontext](https://nikolareljin.github.io/scancontext/) | Local-first medical image and report viewer with optional AI. Not a medical device. |
| [nr-post-exporter](https://nikolareljin.github.io/nr-post-exporter/) | Moves a single WordPress post between sites with fields, terms and revisions. |
| [gutenberg-stocks](https://nikolareljin.github.io/gutenberg-stocks/) | WordPress Gutenberg block rendering stock data via Alphavantage and React. |
| [home-monitor](https://github.com/nikolareljin/home-monitor) | Django, React and a local model watching air, weather and sensors; Home Assistant sync. |
| [nomisma](https://github.com/nikolareljin/nomisma) | Coin analysis and cataloguing with a digital microscope, valuation and eBay integration. |

## Terminal and desktop

| | |
|---|---|
| [vellum](https://github.com/nikolareljin/vellum) | Rich Markdown viewer for the terminal — highlighting, inline images, search, TUI. |
| [image-view](https://github.com/nikolareljin/image-view) | Lightweight Rust CLI for terminal image previews and directory browsing. |
| [agentvault](https://github.com/nikolareljin/agentvault) | CLI and TUI for managing and proxying AI agents, keys and instructions. |
| [spank](https://github.com/nikolareljin/spank) | Linux laptop accelerometer impact detector for Lenovo and IIO systems. |

---

Everything here lives at [github.com/nikolareljin](https://github.com/nikolareljin).
