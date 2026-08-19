#!/usr/bin/env bun
// PreToolUse hook: give mcp__pty__run the same plan-mode treatment Claude
// Code gives the native Bash tool.
//
// WHY THIS EXISTS
// In plan mode Claude Code permits a tool call only when the tool reports
// isReadOnly(input) === true. Bash computes that PER COMMAND (`ls` yes,
// `rm -rf` no). An MCP tool can't: its isReadOnly() is the static
// `annotations.readOnlyHint`, which ignores the input — so with Bash
// deny-listed and mcp__pty__run as its replacement, plan mode had no shell
// at all, not even `ls`. This hook restores the per-command half: it
// classifies the command and returns `allow` for read-only ones.
//
// It only ever WIDENS in plan mode and never narrows elsewhere:
//   • not plan mode          → silent passthrough (zero opinion)
//   • plan + read-only cmd   → allow
//   • plan + anything else   → silent passthrough, so Claude Code's built-in
//                              "Cannot call <tool> while in plan mode" gate
//                              still blocks it and the user can approve.
// Classification failure of any kind falls through to that gate, so the
// failure mode is "blocked in plan mode", never "write executed in plan mode".
//
// The read_pty / list_ptys / spawn_pty / send_keys / kill_pty tools need no
// hook: they carry honest readOnlyHint annotations in the server itself.

interface HookInput {
  permission_mode?: string;
  tool_name?: string;
  tool_input?: { command?: string };
}

// ── read-only command vocabulary ──────────────────────────────────────────
// Heads that cannot mutate anything on their own. Mirrors Claude Code's own
// read-only sets (src/utils/shell/readOnlyCommandValidation.ts), plus the
// obvious inspection tools.
const READ_ONLY_HEADS = new Set([
  // search
  "find", "grep", "rg", "ag", "ack", "locate", "which", "whereis", "type",
  // read / slice / transform on stdout
  "cat", "bat", "head", "tail", "wc", "stat", "file", "strings", "jq", "yq",
  "awk", "cut", "sort", "uniq", "tr", "column", "fold", "nl", "rev", "tee",
  "diff", "cmp", "comm", "md5", "md5sum", "shasum", "sha256sum", "base64",
  "xxd", "od", "sed",
  // listing / paths
  "ls", "tree", "du", "df", "basename", "dirname", "realpath", "readlink",
  "pwd", "cd",
  // trivial output
  "echo", "printf", "true", "false", ":", "seq", "test", "[", "sleep",
  // machine / process facts
  "date", "uname", "hostname", "whoami", "id", "env", "printenv", "ps",
  "uptime", "getconf", "sw_vers", "arch", "groups", "locale",
  // version probes are read-only regardless of the binary
  "node", "bun", "python3", "git", "gh", "docker", "tmux", "npm", "cargo",
  "go", "rustc", "swift", "brew", "kubectl", "terraform", "claude",
]);

// Heads reachable only via an explicit read-only subcommand allowlist. Any
// head listed here but absent from SUBCOMMANDS is rejected outright.
const SUBCOMMANDS: Record<string, Set<string>> = {
  git: new Set([
    "status", "log", "diff", "show", "blame", "branch", "tag", "remote",
    "rev-parse", "rev-list", "describe", "ls-files", "ls-remote", "ls-tree",
    "shortlog", "reflog", "cat-file", "name-rev", "whatchanged", "grep",
    "count-objects", "symbolic-ref", "check-ignore", "config", "stash",
    "worktree", "notes", "bisect",
  ]),
  gh: new Set(["pr", "issue", "run", "repo", "release", "api", "auth", "search", "workflow"]),
  docker: new Set(["ps", "images", "logs", "inspect", "version", "info", "top", "port", "stats", "diff", "history"]),
  tmux: new Set([
    "list-windows", "list-panes", "list-sessions", "list-clients", "list-keys",
    "list-commands", "capture-pane", "display-message", "show-options",
    "show-environment", "has-session", "info", "lsw", "lsp", "ls",
  ]),
  npm: new Set(["ls", "list", "view", "info", "outdated", "why", "config", "root", "prefix", "bin", "search", "audit"]),
  cargo: new Set(["tree", "search", "metadata", "verify-project", "locate-project"]),
  go: new Set(["list", "env", "version", "doc", "vet"]),
  brew: new Set(["list", "info", "search", "config", "deps", "outdated", "--prefix"]),
  kubectl: new Set(["get", "describe", "logs", "explain", "top", "api-resources", "api-versions", "version", "config"]),
  terraform: new Set(["show", "output", "providers", "validate", "version", "fmt"]),
  claude: new Set(["--version", "-v", "mcp", "config", "doctor"]),
  // interpreters: a bare `--version`/`-v` probe only (see isVersionProbe)
  node: new Set(), bun: new Set(), python3: new Set(), rustc: new Set(),
  swift: new Set(), git_placeholder: new Set(),
};

// Subcommands above that are read-only ONLY as a bare listing — any of these
// flags turns them into a write.
const WRITE_FLAGS = new Set([
  "-d", "-D", "-m", "-M", "-f", "--force", "--delete", "--set", "--unset",
  "--add", "--edit", "--replace-all", "--set-upstream", "--move", "--create",
  "--prune", "--rename", "-i", "--in-place", "--write", "-w", "--fix",
]);
const GIT_BARE_ONLY = new Set(["branch", "tag", "config", "stash", "worktree", "notes", "bisect", "remote"]);
const GIT_SUBSUB_READ = new Set(["list", "show", "get", "get-all", "get-regexp", "-l", "--list", "--get", "-v", "--verbose", "log"]);

function isVersionProbe(argv: string[]): boolean {
  return argv.length === 2 && ["--version", "-v", "-V", "--help", "-h"].includes(argv[1]);
}

// Tokenize one segment, respecting quotes well enough that quoted separators
// never masquerade as real ones. Unbalanced quotes → null (reject).
function tokenize(segment: string): string[] | null {
  const out: string[] = [];
  let cur = "";
  let quote: string | null = null;
  for (let i = 0; i < segment.length; i++) {
    const c = segment[i];
    if (quote) {
      if (c === "\\" && quote === '"') { cur += segment[++i] ?? ""; continue; }
      if (c === quote) { quote = null; continue; }
      cur += c;
      continue;
    }
    if (c === "'" || c === '"') { quote = c; continue; }
    if (c === "\\") { cur += segment[++i] ?? ""; continue; }
    if (/\s/.test(c)) { if (cur) { out.push(cur); cur = ""; } continue; }
    cur += c;
  }
  if (quote) return null;
  if (cur) out.push(cur);
  return out;
}

// Split on shell separators that are OUTSIDE quotes. Anything hidden inside
// quotes stays in its segment, where it either parses as a normal argument or
// trips the head check — both safe outcomes.
function splitSegments(command: string): string[] | null {
  const segs: string[] = [];
  let cur = "";
  let quote: string | null = null;
  for (let i = 0; i < command.length; i++) {
    const c = command[i];
    if (quote) {
      if (c === "\\" && quote === '"') { cur += c + (command[++i] ?? ""); continue; }
      if (c === quote) quote = null;
      cur += c;
      continue;
    }
    if (c === "'" || c === '"') { quote = c; cur += c; continue; }
    if (c === "\\") { cur += c + (command[++i] ?? ""); continue; }
    if (c === ";" || c === "\n" || c === "&" || c === "|") {
      if ((c === "&" || c === "|") && command[i + 1] === c) i++; // && ||
      segs.push(cur);
      cur = "";
      continue;
    }
    cur += c;
  }
  if (quote) return null;
  segs.push(cur);
  return segs.filter((s) => s.trim());
}

// Pull out $( … ) and ` … ` bodies so they get classified as commands in
// their own right rather than passing as inert argument text.
function extractSubstitutions(command: string): { stripped: string; inner: string[] } | null {
  const inner: string[] = [];
  let stripped = "";
  for (let i = 0; i < command.length; i++) {
    if (command[i] === "$" && command[i + 1] === "(") {
      let depth = 1;
      let j = i + 2;
      let body = "";
      while (j < command.length && depth > 0) {
        if (command[j] === "(") depth++;
        else if (command[j] === ")") { depth--; if (!depth) break; }
        body += command[j++];
      }
      if (depth) return null; // unbalanced — reject
      inner.push(body);
      i = j;
      stripped += "SUBST";
      continue;
    }
    if (command[i] === "`") {
      const end = command.indexOf("`", i + 1);
      if (end === -1) return null;
      inner.push(command.slice(i + 1, end));
      i = end;
      stripped += "SUBST";
      continue;
    }
    stripped += command[i];
  }
  return { stripped, inner };
}

// A redirection writes to the filesystem. /dev/null and fd-dup are fine.
function hasWritingRedirect(segment: string): boolean {
  const cleaned = segment
    .replace(/[12]?>>?\s*\/dev\/(null|stderr|stdout)/g, "")
    .replace(/[12]>&[12]/g, "")
    .replace(/&>\s*\/dev\/null/g, "");
  return />/.test(cleaned);
}

function segmentIsReadOnly(segment: string): boolean {
  if (hasWritingRedirect(segment)) return false;
  const tokens = tokenize(segment);
  if (!tokens || !tokens.length) return false;

  // drop leading VAR=value assignments
  let i = 0;
  while (i < tokens.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[i])) i++;
  const argv = tokens.slice(i);
  if (!argv.length) return false; // bare assignment mutates shell state

  const head = argv[0].replace(/^.*\//, ""); // /bin/ls → ls
  if (head === "sudo" || head === "doas" || head === "env" && argv.length > 1) return false;
  if (!READ_ONLY_HEADS.has(head)) return false;

  // find can execute or delete
  if (head === "find" && argv.some((a) => ["-exec", "-execdir", "-delete", "-ok", "-okdir", "-fprint"].includes(a)))
    return false;
  // sed/awk/tee only read when they aren't writing
  if (head === "sed" && argv.some((a) => a === "-i" || a.startsWith("-i") || a === "--in-place")) return false;
  if (head === "tee") return false; // tee's whole job is writing
  if (head === "cd") return true;

  const subs = SUBCOMMANDS[head];
  if (!subs) return true; // plain read-only binary, no subcommand grammar
  if (isVersionProbe(argv)) return true;
  const sub = argv.slice(1).find((a) => !a.startsWith("-"));
  const subOrFlag = sub ?? argv[1];
  if (!subOrFlag || !subs.has(subOrFlag)) return false;

  if (head === "git" && GIT_BARE_ONLY.has(subOrFlag)) {
    const rest = argv.slice(argv.indexOf(subOrFlag) + 1);
    if (rest.some((a) => a.startsWith("-") && WRITE_FLAGS.has(a))) return false;
    // `git config foo.bar value` writes; `git config --get foo.bar` reads
    if (subOrFlag === "config" && !rest.some((a) => GIT_SUBSUB_READ.has(a))) return false;
    if (["stash", "worktree", "notes", "bisect"].includes(subOrFlag)) {
      const next = rest.find((a) => !a.startsWith("-"));
      if (!next || !GIT_SUBSUB_READ.has(next)) return false;
    }
  }
  if (head === "gh") {
    const rest = argv.slice(argv.indexOf(subOrFlag) + 1);
    if (subOrFlag === "api") {
      if (rest.some((a) => ["-X", "--method", "-f", "--field", "-F", "--raw-field", "--input"].includes(a))) return false;
    } else {
      const verb = rest.find((a) => !a.startsWith("-"));
      if (!verb || !["view", "list", "diff", "checks", "status", "ls"].includes(verb)) return false;
    }
  }
  if (head === "kubectl" && subOrFlag === "config") {
    const rest = argv.slice(argv.indexOf(subOrFlag) + 1);
    const verb = rest.find((a) => !a.startsWith("-"));
    if (!verb || !["view", "get-contexts", "current-context"].includes(verb)) return false;
  }
  if (head === "npm" && subOrFlag === "config") {
    const rest = argv.slice(argv.indexOf(subOrFlag) + 1);
    const verb = rest.find((a) => !a.startsWith("-"));
    if (!verb || !["get", "list", "ls"].includes(verb)) return false;
  }
  return true;
}

export function isReadOnlyCommand(command: string): boolean {
  if (!command.trim()) return false;
  const ex = extractSubstitutions(command);
  if (!ex) return false;
  const parts = [ex.stripped, ...ex.inner];
  for (const part of parts) {
    const segs = splitSegments(part);
    if (!segs) return false;
    for (const seg of segs) {
      // a substitution body may itself contain substitutions
      const nested = extractSubstitutions(seg);
      if (!nested) return false;
      if (nested.inner.length && !nested.inner.every(isReadOnlyCommand)) return false;
      if (!segmentIsReadOnly(nested.stripped)) return false;
    }
  }
  return true;
}

// ── hook entrypoint ───────────────────────────────────────────────────────
if (import.meta.main) {
  let raw = "";
  for await (const chunk of Bun.stdin.stream()) raw += Buffer.from(chunk).toString();
  let input: HookInput = {};
  try {
    input = JSON.parse(raw);
  } catch {
    process.exit(0); // unparseable → no opinion
  }
  if (input.permission_mode !== "plan") process.exit(0);
  const command = input.tool_input?.command;
  if (typeof command !== "string" || !isReadOnlyCommand(command)) process.exit(0);
  console.log(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        permissionDecisionReason: "Read-only command is allowed in plan mode (same rule Claude Code applies to Bash)",
      },
    }),
  );
}
