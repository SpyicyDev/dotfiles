#!/usr/bin/env bun
// Classifier tests for pty-plan-mode.ts. The asymmetry matters: a false
// NEGATIVE just means "blocked in plan mode" (annoying), a false POSITIVE
// means a write ran in plan mode (a real bug). Weight the deny cases.
import { isReadOnlyCommand } from "./pty-plan-mode.ts";

const ALLOW = [
  "ls",
  "ls -la ~/code",
  "pwd",
  "cd ~/code/tmux-pty-mcp && ls -la",
  "cat src/server.ts",
  "head -50 src/server.ts | grep import",
  "rg 'widOf' src/",
  "find . -name '*.ts' -not -path './node_modules/*'",
  "git status",
  "git log --oneline | head -20",
  "git diff HEAD~1",
  "git branch",
  "git config --get user.email",
  "git stash list",
  "wc -l src/*.ts",
  "echo hello",
  "node --version",
  "bun -v",
  "tmux list-windows -t '=agents'",
  "tmux capture-pane -p -t @213",
  "gh pr list",
  "gh pr view 42 --json title",
  "docker ps",
  "sed -n '1,50p' src/server.ts",
  "cat $(ls src/*.ts | head -1)",
  "echo \"a; rm -rf /tmp/x\"", // separators inside quotes stay inert text
  "ls -la 2>/dev/null",
  "grep -c foo file.txt && echo done",
  "stat -f %z src/server.ts",
  "npm ls --depth=0",
  "kubectl get pods",
];

const DENY = [
  "rm -rf /tmp/x",
  "mv a b",
  "cp a b",
  "mkdir -p foo",
  "touch foo",
  "chmod +x foo",
  "ln -s a b",
  "echo hi > file.txt",
  "echo hi >> file.txt",
  "cat a.txt > b.txt",
  "ls && rm -rf /tmp/x",
  "ls; rm -rf /tmp/x",
  "ls | xargs rm",
  "cat file $(rm -rf /tmp/x)",
  "cat file `rm -rf /tmp/x`",
  "find . -name '*.log' -delete",
  "find . -name '*.ts' -exec rm {} \\;",
  "sed -i '' 's/a/b/' file.txt",
  "sudo ls",
  "git commit -m wip",
  "git push",
  "git checkout -b feature",
  "git branch -D main",
  "git config user.email me@example.com",
  "git stash pop",
  "git reset --hard",
  "npm install",
  "npm config set foo bar",
  "bun run build",
  "node script.js",
  "python3 script.py",
  "tee out.txt",
  "gh pr merge 42",
  "gh api -X POST /repos/x/y/issues",
  "docker rm -f container",
  "kubectl delete pod foo",
  "kubectl config set-context foo",
  "tmux kill-window -t @213",
  "tmux send-keys -t @213 -l x",
  "export FOO=bar",
  "FOO=bar",
  "curl https://example.com",
  "brew install jq",
  "ls 'unbalanced",
  "",
  "   ",
];

let fail = 0;
for (const c of ALLOW) {
  const ok = isReadOnlyCommand(c);
  if (!ok) { console.log(`FAIL (should ALLOW): ${c}`); fail++; }
}
for (const c of DENY) {
  const ok = isReadOnlyCommand(c);
  if (ok) { console.log(`FAIL (should DENY):  ${c}`); fail++; }
}
console.log(fail ? `\n${fail} FAILURES` : `\nALL PASS (${ALLOW.length} allow, ${DENY.length} deny)`);
process.exit(fail ? 1 : 0);
