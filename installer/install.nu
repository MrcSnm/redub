#!/usr/bin/env nu
# Nushell entry point for redub install (wraps install.ps1 / install.sh).
# Usage:
#   nu install.nu
#   nu install.nu --prefix /custom/path
#   nu install.nu --skip-path

def main [
  --prefix: string = ""
  --skip-path
] {
  let here = ($env.FILE_PWD? | default (pwd))
  let is_windows = ((sys host).name | str downcase | str contains "windows")

  if $is_windows {
    mut args = [
      "-NoProfile"
      "-ExecutionPolicy" "Bypass"
      "-File" ($here | path join "install.ps1")
    ]
    if not ($prefix | is-empty) {
      $args = ($args | append ["-Prefix" $prefix])
    }
    if $skip_path {
      $args = ($args | append "-SkipPath")
    }
    ^powershell ...$args
    let dir = (
      if ($prefix | is-empty) {
        ($env.LOCALAPPDATA | path join "Programs" "redub")
      } else { $prefix }
    )
    print-nu-path-hint $dir
  } else {
    mut env_vars = {}
    if not ($prefix | is-empty) { $env_vars = ($env_vars | insert PREFIX $prefix) }
    if $skip_path { $env_vars = ($env_vars | insert SKIP_PATH "1") }
    with-env $env_vars {
      ^bash ($here | path join "install.sh")
    }
    let bin = ($nu.home-path | path join ".local" "bin")
    print-nu-path-hint $bin
  }
}

def print-nu-path-hint [dir: string] {
  print ""
  print "Nushell — if `redub` is not found in this session:"
  print $"  $env.PATH = ($env.PATH | prepend '($dir)')"
  print "Persist User PATH is already handled by the platform installer when not --skip-path."
}
