#!/usr/bin/env bash
#MISE description="Check the repository against the layout contract in contracts/layout: what each folder may hold and name; changes nothing"
set -euo pipefail

# Every rule prints one line per violation as "<file>: <rule>: <detail>".
# The rules read the files git tracks or would track, so ignored build
# output such as .terraform/ never counts.
root="${MISE_PROJECT_ROOT:?}"
contract="$root/contracts/layout"
layout="$contract/layout.yaml"

layout_value() {
  yq -r "$1" "$layout"
}

repository_files() {
  git -C "$root" ls-files -co --exclude-standard -- "$@" |
    while IFS= read -r file; do
      [[ -f "$root/$file" ]] && printf '%s\n' "$file"
    done
}

extension_pattern() {
  printf '\\.(%s)$' "$(layout_value "$1 | join(\"|\")")"
}

data_files() {
  repository_files "$@" | grep -E "$(extension_pattern .data_extensions)" || true
}

code_files() {
  local code file
  code=$(extension_pattern .code_extensions)
  repository_files "$@" | while IFS= read -r file; do
    if [[ "$file" =~ $code || -x "$root/$file" ]]; then
      printf '%s\n' "$file"
    fi
  done
}

# Prints the files an exception covers, one per line, for the given rule.
excepted_files() {
  local rule="$1" glob file
  while IFS= read -r glob; do
    for file in "$root"/$glob; do
      [[ -f "$file" ]] && printf '%s\n' "${file#"$root"/}"
    done
  done < <(layout_value ".exceptions[] | select(.rule == \"$rule\") | .paths[]")
}

# Cluster and environment names are the folder names under clusters/ and
# environments/; role values such as workload are vocabulary, not names.
defined_names() {
  local folder
  for folder in "$root"/clusters/*/ "$root"/environments/*/; do
    [[ -d "$folder" ]] && basename "$folder"
  done
}

# Prints "<file>: <rule>: <name>" for each defined name that appears as a
# whole token (not part of a word, path segment or DNS name such as
# cluster.local) outside a role: line.
report_names() {
  local rule="$1" names files
  shift
  names=$(defined_names | paste -sd '|' -)
  mapfile -t files < <(data_files "$@")
  [[ -n "$names" ]] && ((${#files[@]})) || return 0
  (cd "$root" && NAMES="$names" RULE="$rule" perl -ne '
    unless (/^\s*role:/) {
      while (/(?<![\w.-])($ENV{NAMES})(?![\w.-])/g) {
        print "$ARGV: $ENV{RULE}: names $1 on line $.\n";
      }
    }
    close ARGV if eof;
  ' "${files[@]}")
}

rule_environments_no_code() {
  local excepted file
  excepted=$(excepted_files environments-no-code)
  while IFS= read -r file; do
    grep -Fxq -- "$file" <<<"$excepted" ||
      printf '%s: environments-no-code: an environment holds data, not code\n' "$file"
  done < <(code_files environments)
}

rule_no_names() {
  report_names no-names packages clusters
}

rule_roots_no_names() {
  report_names roots-no-names roots
}

rule_no_facts() {
  local files patterns allow
  mapfile -t files < <(data_files packages clusters)
  ((${#files[@]})) || return 0
  patterns=$(layout_value '.fact_patterns[] | .name + "\t" + .regex')
  allow=$(layout_value '.fact_allow[]')
  (cd "$root" && PATTERNS="$patterns" ALLOW="$allow" perl -ne '
    BEGIN {
      @patterns = map { [split /\t/, $_, 2] } split /\n/, $ENV{PATTERNS};
      @allow = split /\n/, $ENV{ALLOW};
    }
    my $line = $_;
    $line =~ s/\Q$_\E//g for @allow;
    for my $p (@patterns) {
      print "$ARGV: no-facts: $p->[0] on line $.\n" if $line =~ /$p->[1]/;
    }
    close ARGV if eof;
  ' "${files[@]}")
}

rule_packages_not_executable() {
  local file
  while IFS= read -r file; do
    [[ -x "$root/$file" ]] &&
      printf '%s: packages-not-executable: package files are sourced or run by a task, never executed\n' "$file"
  done < <(repository_files packages)
  return 0
}

rule_task_folder_pairs_package() {
  local pattern folder name
  pattern=$(layout_value .package_pattern)
  for folder in "$root"/.mise/tasks/*/; do
    [[ -d "$folder" ]] || continue
    name=$(basename "$folder")
    [[ "$name" =~ $pattern && ! -d "$root/packages/$name" ]] &&
      printf '.mise/tasks/%s: task-folder-pairs-package: no packages/%s\n' "$name" "$name"
  done
  return 0
}

rule_modules_no_references() {
  local file
  while IFS= read -r file; do
    grep -nE '(^|[^[:alnum:]_.-])(packages|clusters|environments)/' "$root/$file" |
      sed "s|^\([0-9]*\):.*|$file: modules-no-references: references another layer on line \1|" || true
  done < <(code_files modules)
}

# Every hk.pkl glob points into the layout: the part before its first
# wildcard exists, and its first segment is a layout folder, a dot-path such
# as .mise, or a file at the repository root. A renamed folder fails here
# instead of silently leaving an hk step with nothing to match.
rule_hk_globs_current() {
  local folders glob prefix top
  [[ -f "$root/hk.pkl" ]] || return 0
  folders=$(layout_value '.folders | keys | .[]')
  while IFS= read -r glob; do
    prefix="${glob%%\**}"
    [[ "$prefix" == "$glob" ]] || prefix="${prefix%/*}"
    [[ -n "$prefix" ]] || continue
    top="${prefix%%/*}"
    if [[ ! -e "$root/$prefix" ]]; then
      printf 'hk.pkl: hk-globs-current: glob %s names %s, which does not exist\n' "$glob" "$prefix"
    elif [[ "$top" != .* && -d "$root/$top" ]] && ! grep -Fxq -- "$top" <<<"$folders"; then
      printf 'hk.pkl: hk-globs-current: glob %s is under %s/, which is not a layout folder\n' "$glob" "$top"
    fi
  done < <(grep -E '^[[:space:]]*glob[[:space:]]*=' "$root/hk.pkl" | grep -oE '"[^"]+"' | tr -d '"')
}

# An exception whose paths match no file has outlived the code it covered.
rule_exceptions_current() {
  local rule glob matched file
  # shellcheck disable=SC2016 # $rule is a yq variable, not a shell one
  while IFS=$'\t' read -r rule glob; do
    matched=
    for file in "$root"/$glob; do
      [[ -e "$file" ]] && matched=1 && break
    done
    [[ -n "$matched" ]] ||
      printf 'contracts/layout/layout.yaml: exceptions-current: %s exception path %s matches no file; remove it\n' "$rule" "$glob"
  done < <(layout_value '.exceptions[] | .rule as $rule | .paths[] | $rule + "\t" + .')
}

if ! cue vet "$contract/schema.cue" "$layout" >&2; then
  printf 'layout:lint: %s: the layout contract does not match its schema\n' "$layout" >&2
  exit 1
fi

violations=$(
  rule_exceptions_current
  rule_environments_no_code
  rule_no_names
  rule_roots_no_names
  rule_no_facts
  rule_packages_not_executable
  rule_task_folder_pairs_package
  rule_modules_no_references
  rule_hk_globs_current
)
if [[ -n "$violations" ]]; then
  mapfile -t lines <<<"$violations"
  printf 'layout:lint: %s\n' "${lines[@]}" >&2
  exit 1
fi
