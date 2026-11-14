# ODXPilot installer

ODXPilot is an assistant for Odoo administration: people ask in plain language, ODXPilot reads
Odoo to answer, and plans changes as proposals a person approves before anything is written.
This repository holds its installer and the Docker Compose bundle it sets up.

```bash
curl -fsSL https://raw.githubusercontent.com/terrakernel/odxpilot-install/main/install.sh | bash
```

To read it first:

```bash
curl -fsSL https://raw.githubusercontent.com/terrakernel/odxpilot-install/main/install.sh -o install.sh
less install.sh
bash install.sh            # bash install.sh --help for options and unattended installs
```

## What it installs

An ODXPilot stack has three parts. The installer asks which of them run on this machine: all
three, or any of them, with the others on other machines.

| Part | What it does | Image |
|---|---|---|
| **pilot** | ODXPilot: the web UI and chat, the Odoo tools and the roles' policies | `terrakernel/odxpilot` |
| **proxy** | ODXProxy: the gateway to your Odoo (needs an ODXProxy licence) | `terrakernel/odxproxy` |
| **brain** | ODXBrain + odxdocs: finds the Odoo model for a question and your SOP for a task | `terrakernel/odxbrain`, `terrakernel/odxdocs` |

It checks the machine, asks a few questions, generates the keys between the parts (never shown,
stored in files only you can read), downloads ODXBrain's model and corpus pack and checks them
against their SHA-256, starts everything and checks it end to end. A machine whose parts others
connect to writes a hand-over file with its address and keys, which the installer on the next
machine reads. Run it again to upgrade or reconfigure.

## What you need

- Docker with Compose 2.20 or newer, on Linux or macOS (Windows: WSL 2).
- For the proxy: an ODXProxy licence (`license.json`) from [odxproxy.io](https://odxproxy.io).
- For the pilot: your Odoo's address and database, an Odoo user with an API key, and an LLM key
  (OpenAI, Anthropic, Google Vertex AI) or your own OpenAI-compatible server.

The full guide, also without the installer, is in the bundle's `README.md` (attached to each
[release](https://github.com/terrakernel/odxpilot-install/releases)), installed next to
`compose.yaml`.

## Good to know

- **No sign-in yet.** ODXPilot's web UI listens on the machine's loopback, and whoever uses it acts
  as the one role chosen at install.
- **Between machines, the parts talk plain HTTP**, each with its own key: keep them on a private
  network or VPN, or put HTTPS in front.
- **Nothing is written to Odoo without your Approve**, and only when one of your SOPs covers the
  task; nothing is ever deleted. Try it on a test database first.
- Questions, the Odoo data the role may read (masked fields stay masked) and attached files go to
  the LLM you choose.

## Licence

The installer and the bundle in this repository: [MIT](LICENSE). The Docker images and ODXProxy
have their own terms.
