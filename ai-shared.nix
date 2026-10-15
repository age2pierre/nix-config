# Shared LLM provider + LSP server configuration for all AI coding tools
# (opencode, oh-my-pi, zed, fresh-editor).
#
# Providers and LSP servers are defined ONCE here as Nix attrsets, then
# rendered into each tool's native config format by the render functions
# below.  API keys live in agenix secrets (decrypted at login into
# /run/user/1000/agenix) and are referenced at RUNTIME, never inlined at
# eval time — nothing secret ends up in the Nix store:
#   - opencode: whole-config `{file:<path>}` substitution at load.
#   - omp models.yml: `apiKey: "!cat <path>"` shell-command resolution.
#   - omp mcp.json headers: no substitution support; the context7 MCP server
#     is therefore not rendered for omp (still available in opencode).
#
# To add a provider: add an entry to `llmProviders` (point `apiKeyPath` at
# an agenix-decrypted file if the provider needs auth).  To add an LSP: add
# an entry to `lspServers` and make sure its package is in `lspPackages`.
{
  lib,
  pkgs,
  ...
}: let
  # agenix HM secrets decrypt into $XDG_RUNTIME_DIR/agenix (= /run/user/1000/agenix).
  agenixDir = "/run/user/1000/agenix";

  # ---------------------------------------------------------------------------
  # LLM providers — single source of truth.
  #
  # Each provider is OpenAI-compatible (the common denominator across
  # opencode, and omp).
  # `apiKeyPath` is an absolute path to the agenix-decrypted key file (under
  # ${agenixDir}); tools read it at runtime.  Set to null for keyless providers.
  # ---------------------------------------------------------------------------
  llmProviders = {
    ollama-local = {
      displayName = "Ollama (local)";
      baseURL = "http://localhost:11434/v1";
      apiKeyPath = null; # local ollama needs no auth
      models = [
        {
          id = "gemma4:26b-262k";
          name = "Gemma 4 26B (262k)";
          toolCall = true;
          contextWindow = 262144;
          maxTokens = 131072;
        }
        {
          id = "gemma4:26b-131k";
          name = "Gemma 4 26B (131k)";
          toolCall = true;
          maxTokens = 65536;
          contextWindow = 131072;
        }
        {
          id = "gpt-oss:20b-32k";
          name = "GPT OSS 20B 32k";
          contextWindow = 32768;
        }
        {
          id = "gpt-oss:20b-65k";
          name = "GPT OSS 20B 65k";
          contextWindow = 65536;
        }
        {
          id = "gpt-oss:20b-131k";
          name = "GPT OSS 20B 131k";
          contextWindow = 131072;
        }
      ];
    };

    ollama-cloud = {
      displayName = "Ollama (cloud)";
      baseURL = "https://ollama.com/v1";
      apiKeyPath = "${agenixDir}/ollama-key";
      models = [
        {
          id = "glm-5.3";
          name = "GLM 5.3 (cloud, 753B, 1M)";
          toolCall = true;
          input = ["text"];
          contextWindow = 1000000;
        }
        {
          id = "glm-5.3-flash:cloud";
          name = "GLM 5.3 Flash (cloud, vision, 321B, 1M)";
          toolCall = true;
          input = ["text" "image"];
          contextWindow = 1000000;
        }
      ];
    };

    runpod-ct = {
      displayName = "Runpod vLLM CT";
      baseURL = "https://es74iiq7o4ug1m-8000.proxy.runpod.net/v1";
      apiKeyPath = "${agenixDir}/runpod-ct-key";
      models = [
        {
          id = "DiffusionGemma-4-26B";
          name = "Diffusion Gemma 4 26B";
        }
      ];
    };

    runpod-perso = {
      displayName = "Runpod vLLM perso";
      baseURL = "https://dksfdmlaw3prgz-8000.proxy.runpod.net/v1";
      apiKeyPath = "${agenixDir}/runpod-perso-key";
      models = [
        {
          id = "Gemma-4-26B";
          name = "Gemma-4-26B";
        }
        {
          id = "Qwen3.6-35B-A3B-FP8";
          name = "Qwen 3.6 35B A3B FP8";
        }
      ];
    };
  };

  # ---------------------------------------------------------------------------
  # LSP servers — single source of truth.
  #
  # `command` is the binary name; the package must be on PATH (either via
  # home.packages or lspPackages below).
  # ---------------------------------------------------------------------------
  lspServers = {
    nix = {
      command = "nixd";
      autoStart = true;
    };
    typescript = {
      command = "typescript";
      autoStart = true;
    };
    java = {
      command = "jdt-language-server";
      autoStart = false;
    };
    kotlin = {
      command = "kotlin-language-server";
      autoStart = false;
    };
    just = {
      command = "just-lsp";
      autoStart = true;
    };
  };

  # Packages that must be on PATH for LSP servers to be found.
  lspPackages = with pkgs; [
    nixd
    typescript
    jdt-language-server
    kotlin-language-server
    just-lsp
  ];

  # ---------------------------------------------------------------------------
  # MCP servers — single source of truth.
  #
  # Each entry is a remote HTTP MCP server (the common case for hosted
  # services like Context7).  `headers` maps to per-tool header fields.
  # Header values use opencode's `{file:<path>}` substitution (resolved at
  # load); omp's mcp.json has no substitution support, so context7 is not
  # rendered for omp (see toOmpMcp).
  # ---------------------------------------------------------------------------
  mcpServers = {
    context7 = {
      url = "https://mcp.context7.com/mcp";
      type = "remote"; # opencode's name for HTTP MCP
      headers = {
        CONTEXT7_API_KEY = "{file:${agenixDir}/context7-key}";
      };
    };
  };

  # ---------------------------------------------------------------------------
  # Render: opencode MCP (`programs.opencode.settings.mcp`)
  # opencode uses { type = "remote"; url; headers; enabled; }
  # ---------------------------------------------------------------------------
  toOpencodeMcp =
    lib.mapAttrs (name: s: {
      type = s.type;
      url = s.url;
      headers = s.headers;
      enabled = true;
    })
    mcpServers;

  # ---------------------------------------------------------------------------
  # Render: oh-my-pi mcp.json (~/.omp/agent/mcp.json)
  # omp uses { "mcpServers": { name: { type: "http"; url; headers; } } }
  # omp does not substitute {file:}/{env:} in mcp.json headers, so servers
  # whose auth needs a secret (context7) are omitted — they stay available
  # in opencode.
  # ---------------------------------------------------------------------------
  toOmpMcp = builtins.toJSON {
    "$schema" = "https://raw.githubusercontent.com/can1357/oh-my-pi/main/packages/coding-agent/src/config/mcp-schema.json";
    mcpServers =
      lib.mapAttrs (name: s: {
        type = "http";
        url = s.url;
        headers = s.headers;
      })
      (removeAttrs mcpServers ["context7"]);
  };

  # ---------------------------------------------------------------------------
  # Render: opencode (`programs.opencode.settings.provider`)
  # ---------------------------------------------------------------------------
  toOpencodeProviders =
    lib.mapAttrs (id: p: {
      name = p.displayName;
      npm = "@ai-sdk/openai-compatible";
      options =
        {baseURL = p.baseURL;}
        // lib.optionalAttrs (p.apiKeyPath != null) {
          # opencode whole-config substitution: resolved from the agenix
          # file at opencode load time.
          apiKey = "{file:${p.apiKeyPath}}";
        };
      models = lib.listToAttrs (map (m:
        lib.nameValuePair m.id ({
            name = m.name;
          }
          // lib.optionalAttrs (m.toolCall or false) {
            tool_call = true;
          }
          // lib.optionalAttrs (m.maxTokens or null != null) {
            maxTokens = m.maxTokens;
          }))
      p.models);
    })
    llmProviders;

  # ---------------------------------------------------------------------------
  # Render: oh-my-pi models.yml (~/.omp/agent/models.yml)
  # omp resolves credentials from env vars OR inline apiKey values.  We inline
  # the keys from ./secrets so nothing leaks into session env vars.
  #
  # We emit each provider as a *full custom provider* (with an explicit
  # `models` list) rather than an override-only provider.  Override-only
  # providers merge with omp's built-in provider registry by id, and the
  # built-in `ollama` provider routes to the native /api/chat endpoint —
  # which 404s against api.ollama.com (an OpenAI-compatible endpoint, not
  # native Ollama).  Full custom providers use the `api` field we set and
  # never fall back to native discovery.
  #
  # `openai-completions` is omp's name for the standard OpenAI Chat
  # Completions endpoint (/chat/completions) — NOT OpenAI's newer
  # /responses endpoint (which omp calls `openai-responses` and which
  # returns 405 against Ollama Cloud / vLLM / other compat servers).
  # ---------------------------------------------------------------------------
  toOmpProvidersYaml = lib.generators.toYAML {} {
    providers = lib.mapAttrs (id: p:
      {
        baseUrl = p.baseURL;
        api = "openai-completions";
        models = map (m:
          {
            id = m.id;
            name = m.name;
            api = "openai-completions";
          }
          // lib.optionalAttrs (m ? input) {
            input = m.input;
          }
          // lib.optionalAttrs (m ? contextWindow) {
            contextWindow = m.contextWindow;
          }
          // lib.optionalAttrs (m ? maxTokens) {
            maxTokens = m.maxTokens;
          })
        p.models;
      }
      // lib.optionalAttrs (p.apiKeyPath != null) {
        # omp shell-command apiKey resolution: runs at omp startup,
        # trimmed stdout is used as the key (v18.4.4 providers.md).
        apiKey = "!cat ${p.apiKeyPath}";
      }
      // lib.optionalAttrs (p.apiKeyPath == null) {
        auth = "none";
      })
    llmProviders;
  };

  # ---------------------------------------------------------------------------
  # Render: fresh-editor LSP config (`programs.fresh-editor.settings.lsp`)
  # ---------------------------------------------------------------------------
  toFreshLsp =
    lib.mapAttrs (lang: s: [
      {
        command = s.command;
        enabled = true;
        auto_start = s.autoStart;
        process_limits = {
          enabled = true;
          max_memory_percent = 50;
          max_cpu_percent = 90;
        };
      }
    ])
    lspServers;

  # ---------------------------------------------------------------------------
  # Render: zed extraPackages (LSP binaries on PATH for zed's auto-discovery)
  # ---------------------------------------------------------------------------
  toZedExtraPackages = lspPackages;

  # oh-my-pi extensions from flake inputs / pinned npm sources.
  #
  # omp auto-discovers ~/.omp/agent/extensions/*.{ts,js} and its loader rewrites
  # legacy `@mariozechner/*` imports onto the host-bundled copies, so single-file
  # upstream extensions load without their peerDependencies installed.
  piBrainstorm = pkgs.fetchFromGitHub {
    owner = "paulmupeters";
    repo = "pi-brainstorm";
    rev = "e5d2bab28a7ed723933a1da2ea2f6b41209c173e"; # main
    hash = "sha256-VkZgPVrg53QN2lxQhOu08zVJNZUcmvfCTm7hyUB7ZVo=";
  };

  # ---------------------------------------------------------------------------
  # oh-my-pi model role assignments (consumed by `ompSettings` below).
  ompModelRoles = let
    # Flash (321B, vision) — always-on roles: interactive loop, high-frequency
    # helpers, 9-way task concurrency, and vision (753B is text-only).
    flash = "ollama-cloud/glm-5.3-flash:cloud";
    # 753B non-flash — rare, judgment-heavy roles where extra parameters pay.
    big = "ollama-cloud/glm-5.3";
  in {
    default = flash;
    smol = flash;
    task = flash;
    commit = flash;
    title = flash;
    vision = flash;
    advisor = flash;
    plan = big;
    slow = big;
    designer = big;
  };

  # ---------------------------------------------------------------------------
  # oh-my-pi settings (~/.omp/agent/config.yml).  Migrated from the previous
  # hand-written config so the file is now fully Nix-managed (a symlink into
  # the store); `/settings` and `omp config set` are read-only at runtime.
  # `modelRoles` comes from `ompModelRoles` above; the rest preserves the
  # values previously set interactively (theme, statusLine, setupVersion, …).
  # Add a key here, never edit config.yml by hand.
  # ---------------------------------------------------------------------------
  ompSettings = {
    symbolPreset = "nerd";
    theme.dark = "titanium";
    setupVersion = 1;
    # The setup wizard rewrites config.yml when it runs (even when skipped),
    # but config.yml is a read-only store symlink — omp died with EROFS after
    # the "What's New" screen. `omp -c` only worked because resume short-
    # circuits wizard scene collection. Disable it: this file is the single
    # source of settings and there is nothing to persist.
    # (OMP_SKIP_SETUP=true is the equivalent env-var escape hatch.)
    startup.setupWizard = false;
    modelRoles = ompModelRoles;
    defaultThinkingLevel = "auto";
    statusLine.showHookStatus = true;
    tui.textSizing = false;
    hideThinkingBlock = false;
    inspect_image.enabled = true;
    dev.autoqa = false;
    task.maxConcurrency = 9;
  };

  # omp's config.yml is YAML; nested keys become dotted paths via the
  # generator.  lib.generators.toYAML handles nested attrsets natively.
  toOmpConfigYaml = lib.generators.toYAML {} ompSettings;
in {
  inherit
    llmProviders
    lspServers
    lspPackages
    mcpServers
    piBrainstorm
    toOpencodeProviders
    toOpencodeMcp
    toOmpProvidersYaml
    toOmpMcp
    toFreshLsp
    toZedExtraPackages
    ompModelRoles
    toOmpConfigYaml
    ;
}
