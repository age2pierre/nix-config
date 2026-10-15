let
  system-tuxedo = "age1lkj8wnzucnxal5j4v8xn7e6w9x2lq2vls9y0ggdguy02a2nqds5qz4lzs4";
  user-age2pierre = "age1hfxqmdkx5qdvunyqj0arzdhs5ks4ve6r4napesl4p0vut4v7ee4q3xcayh";
in {
  "secrets/ollama-key.age".publicKeys = [ system-tuxedo user-age2pierre ];
  "secrets/runpod-ct-key.age".publicKeys = [ system-tuxedo user-age2pierre ];
  "secrets/runpod-perso-key.age".publicKeys = [ system-tuxedo user-age2pierre ];
  "secrets/context7-key.age".publicKeys = [ system-tuxedo user-age2pierre ];
  "secrets/wifi-env.age".publicKeys = [ system-tuxedo user-age2pierre ];
  "secrets/searxng-env.age".publicKeys = [ system-tuxedo user-age2pierre ];
  "secrets/ssh-id-ed25519.age".publicKeys = [ system-tuxedo user-age2pierre ];
  "secrets/ssh-id-rsa.age".publicKeys = [ system-tuxedo user-age2pierre ];
  "secrets/kubeconfig.age".publicKeys = [ system-tuxedo user-age2pierre ];
}