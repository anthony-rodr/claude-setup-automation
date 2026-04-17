/**
 * Master Electronics — Developer Environment Setup Guide
 *
 * A conversational CLI chatbot that guides new employees through the
 * user-side setup after IT has installed all tools via NinjaOne.
 *
 * How employees access this:
 *   Double-click the "Developer Setup Guide" shortcut on their desktop.
 *   The shortcut launches Start-DevSetupGuide.cmd which opens this script.
 *
 * ── Prerequisites ────────────────────────────────────────────────────────────
 *
 * FOR IT (one-time, company-level):
 *   Anthropic API Key — this chatbot is powered by the Anthropic API.
 *   Obtain from console.anthropic.com using the company's billing account.
 *   The installer stores it as ANTHROPIC_API_KEY (machine env var) so all
 *   users on this machine can run the chatbot without any extra configuration.
 *   Pass it to Install-DevEnvironment.ps1 via: -AnthropicApiKey "sk-ant-..."
 *
 * FOR EACH EMPLOYEE (guided by this chatbot at Step 6):
 *   Claude Account — every employee needs a personal Claude account at
 *   claude.ai to authenticate Claude Code. A free account is sufficient;
 *   no billing required for individual users. The chatbot walks them through
 *   creating or signing into their account and completing OAuth setup.
 *
 * ── Setup flow ───────────────────────────────────────────────────────────────
 *   1. GitHub account (create or sign in, username convention firstname-lastinitial)
 *   2. GitHub CLI auth to the Enterprise endpoint
 *   3. GitHub org membership — auto-discovered via API, manual fallback if not yet assigned
 *   4. Two-factor authentication on GitHub
 *   5. Git identity (user.name / user.email)
 *   6. Claude Code authentication — requires a free claude.ai account
 *   7. AWS CLI profile (CloudOps role only)
 *   8. Final verification checklist
 */

import Anthropic    from '@anthropic-ai/sdk';
import readline     from 'readline';
import { exec }     from 'child_process';
import { promisify } from 'util';

const execAsync = promisify(exec);

// ─────────────────────────────────────────────────────────────────────────────
// Configuration
// ─────────────────────────────────────────────────────────────────────────────
const GITHUB_ENTERPRISE_HOST = 'github.masterelectronics.com';

// ─────────────────────────────────────────────────────────────────────────────
// Verify API key is available before doing anything else
// ─────────────────────────────────────────────────────────────────────────────
if (!process.env.ANTHROPIC_API_KEY) {
  console.error('\n  ERROR: ANTHROPIC_API_KEY is not set.');
  console.error('  Please contact IT support (#it-support in Slack) to get this configured.\n');
  process.exit(1);
}

// ─────────────────────────────────────────────────────────────────────────────
// Claude client
// ─────────────────────────────────────────────────────────────────────────────
const client = new Anthropic();

// ─────────────────────────────────────────────────────────────────────────────
// System prompt — large, stable, cached with prompt caching
// ─────────────────────────────────────────────────────────────────────────────
const SYSTEM_PROMPT = `You are the Master Electronics Developer Environment Setup Guide — a friendly, \
patient assistant that helps new employees complete their developer environment setup \
after IT has already installed all the software.

## Your role
Guide the employee step-by-step through every user-side configuration task. \
Use the run_command tool to verify their progress before moving to each next step. \
If something isn't working, diagnose the problem and help them fix it. \
Never skip a step or assume it's done without checking.

## Company context
- Company: Master Electronics
- GitHub Enterprise host: ${GITHUB_ENTERPRISE_HOST}
- GitHub username convention: firstname-lastinitial  (e.g. John Smith → john-s)
- GitHub org assignment: Employees are assigned to one or more department orgs by their \
  manager or IT. The chatbot discovers org memberships automatically via the GitHub API \
  once the employee is authenticated. If they are not yet in any org, they should contact \
  their manager or supervisor to be added.
- IT support: #it-support channel in Slack
- All employees complete steps 1–6. CloudOps engineers also complete step 7.

## Prerequisites the employee needs to know about
Before starting, let them know two accounts are involved in this setup:
  1. GitHub account — for source control (handled in Step 1). Free.
  2. Claude account — for Claude Code (handled in Step 6). Free personal account \
     at claude.ai. This is separate from any company subscription. If they already \
     use Claude at claude.ai, they can use that same account.
Mention this at the very beginning of the conversation so they are not surprised \
when Step 6 asks them to create or sign into claude.ai.

## Setup checklist

### Step 1 — GitHub account
Ask if they already have a GitHub.com account.
  YES → Ask for their username. Verify it follows the firstname-lastinitial convention \
        (e.g., john-s for John Smith). If it doesn't match, guide them to update it at \
        github.com/settings/admin. They should use their @masterelectronics.com email.
  NO  → Walk them through creating an account at github.com/join:
        • Recommend firstname-lastinitial as their username
        • They MUST use their @masterelectronics.com email
        • Guide them through the email verification step before continuing

### Step 2 — GitHub CLI authentication
Run: gh auth status --hostname ${GITHUB_ENTERPRISE_HOST}
If not authenticated:
  Have them run: gh auth login --hostname ${GITHUB_ENTERPRISE_HOST}
  Walk them through: HTTPS → Login with a web browser → complete browser flow → return here
After completion, verify with: gh auth status --hostname ${GITHUB_ENTERPRISE_HOST}

### Step 3 — GitHub org membership
Once authenticated, run: gh api user/orgs --hostname ${GITHUB_ENTERPRISE_HOST}
Interpret the result:
  • Orgs listed → Show the org name(s), confirm it matches what their manager told them. \
    If they're in multiple orgs, list them all. Ask if this looks right.
  • Empty list ([]) → They haven't been assigned to an org yet. This is normal for new \
    accounts. Tell them to reach out to their manager or supervisor to receive an org \
    invitation, then check their corporate email for the invite link. They can re-run \
    this guide after accepting the invite. Continue to the next step for now.
  • Not yet assigned → If they know their org name from their manager, note it. Tell \
    them to accept the invite email when it arrives.
Do NOT block on org membership — the remaining steps work independently.

### Step 4 — Two-factor authentication (2FA)
Direct them to: github.com/settings/security → Two-factor authentication → Enable.
Recommend an authenticator app: Microsoft Authenticator or Google Authenticator (not SMS).
Ask them to confirm when 2FA is active and they have saved their recovery codes.

### Step 5 — Git identity
Run: git config --global user.name
Run: git config --global user.email
If either is missing or incorrect, have them set both:
  git config --global user.name "First Last"
  git config --global user.email "first.last@masterelectronics.com"
Verify both are set correctly by running the checks again.

### Step 6 — Claude Code authentication
Claude Code requires each employee to have a personal Claude account at claude.ai.
This is free — no billing or subscription needed for individual users.

Before they run anything, ask if they already have a claude.ai account:
  YES → They can use that existing account when the browser opens.
  NO  → Have them go to claude.ai and create a free account first, then return here.
        They should use their @masterelectronics.com email if possible, but a personal
        email is also acceptable — this is their individual developer account.

Once they have an account ready:
  Tell them to open a NEW terminal window (keep this one open) and run: claude
  Claude Code will launch an OAuth page in their browser — they sign in with their
  claude.ai account to authorize Claude Code on this machine.
  After the browser flow completes, return here and verify with: claude --version
  If 'claude' is not found, check: npm list -g @anthropic-ai/claude-code

### Step 7 — AWS CLI profile (CloudOps team only)
Ask if they are on the CloudOps team.
  YES → Walk them through:
        1. Run: aws configure --profile master-electronics
        2. They need their AWS Access Key ID and Secret Access Key from IT (#it-support)
        3. Default region: us-east-1 (unless IT specified otherwise)
        4. Default output format: json
        5. Verify: aws sts get-caller-identity --profile master-electronics
        If they don't have credentials yet, tell them to request from #it-support and \
        return to complete this step when ready.
  NO  → Skip this step.

### Step 8 — Final verification
Run all of these and confirm each passes:
  git --version
  node --version
  npm --version
  claude --version
  gh auth status --hostname ${GITHUB_ENTERPRISE_HOST}
  code --version
  python --version
  git config --global user.name
  git config --global user.email

For each result, tell them clearly: ✓ OK or ✗ Needs attention (with what to do).
When all pass, congratulate them! Remind them that #it-support is always available.

## Using run_command
Before and after each step, run the relevant verification command. \
Show the employee what you're checking and explain the output in plain English. \
If a command exits non-zero, help diagnose and fix the issue before moving on.

## Tone
Warm, encouraging, specific, and patient. Use simple language — assume comfort with \
computers but not necessarily with developer tools. If someone is stuck, try a different \
explanation. Never make them feel bad for not knowing something.`;

// ─────────────────────────────────────────────────────────────────────────────
// Tool definition
// ─────────────────────────────────────────────────────────────────────────────
const tools = [
  {
    name: 'run_command',
    description:
      "Runs a read-only verification command on the employee's Windows machine " +
      'and returns the output. Use this to check tool versions, git configuration, ' +
      'GitHub CLI auth status, org membership, and similar read-only checks. ' +
      'Do not run commands that write files, change settings, or install software.',
    input_schema: {
      type: 'object',
      properties: {
        command: {
          type: 'string',
          description: 'The PowerShell command to execute.',
        },
        description: {
          type: 'string',
          description: 'Short human-readable description of what this command checks.',
        },
      },
      required: ['command', 'description'],
    },
  },
];

// ─────────────────────────────────────────────────────────────────────────────
// Tool executor — read-only operations only
// ─────────────────────────────────────────────────────────────────────────────
const BLOCKED_PATTERNS = [
  /rm\s+-[rf]/i,
  /Remove-Item.*-Recurse/i,
  /Format-Volume/i,
  /del\s+\/[sf]/i,
  /rmdir\s+\/s/i,
  /reg\s+(delete|add)/i,
  /netsh.*delete/i,
  /Stop-Process/i,
  /Set-Content/i,
  /Out-File/i,
  /Add-Content/i,
  /Set-ItemProperty/i,
  // Single > is write-redirect; >> is append — both blocked
  /(?<![>])[>](?![>])/,
  /[>]{2}/,
];

async function runCommand(command) {
  for (const pattern of BLOCKED_PATTERNS) {
    if (pattern.test(command)) {
      return {
        stdout:   '',
        stderr:   `Command blocked for safety (matched pattern: ${pattern.source}).`,
        exitCode: -1,
      };
    }
  }

  try {
    // Escape inner double-quotes and wrap for PowerShell
    const safeCmd = command.replace(/"/g, '\\"');
    const { stdout, stderr } = await execAsync(
      `powershell.exe -NonInteractive -NoProfile -Command "${safeCmd}"`,
      { timeout: 20000 }
    );
    return { stdout: stdout.trim(), stderr: stderr.trim(), exitCode: 0 };
  } catch (err) {
    return {
      stdout:   err.stdout?.trim() ?? '',
      stderr:   err.stderr?.trim() ?? err.message,
      exitCode: err.code ?? 1,
    };
  }
}

function formatToolResult({ stdout, stderr, exitCode }) {
  const lines = [`Exit code: ${exitCode}`];
  if (stdout) lines.push(`Output:\n${stdout}`);
  if (stderr) lines.push(`Stderr:\n${stderr}`);
  if (!stdout && !stderr) lines.push('(no output)');
  return lines.join('\n');
}

// ─────────────────────────────────────────────────────────────────────────────
// Streaming agentic loop
// ─────────────────────────────────────────────────────────────────────────────
async function chat(messages) {
  let currentTool = null;
  let inputJson   = '';
  let toolCalls   = [];

  process.stdout.write('\nAssistant: ');

  const stream = client.messages.stream({
    model:      'claude-opus-4-6',
    max_tokens: 8096,
    thinking:   { type: 'adaptive' },
    system: [
      {
        type:          'text',
        text:          SYSTEM_PROMPT,
        cache_control: { type: 'ephemeral' },   // Cache the large system prompt
      },
    ],
    tools,
    messages,
  });

  for await (const event of stream) {
    switch (event.type) {
      case 'content_block_start':
        if (event.content_block.type === 'tool_use') {
          currentTool = { id: event.content_block.id, name: event.content_block.name };
          inputJson   = '';
        }
        break;

      case 'content_block_delta':
        if (event.delta.type === 'text_delta') {
          process.stdout.write(event.delta.text);
        } else if (event.delta.type === 'input_json_delta') {
          inputJson += event.delta.partial_json;
        }
        break;

      case 'content_block_stop':
        if (currentTool) {
          let input = {};
          try { input = JSON.parse(inputJson); } catch {}
          toolCalls.push({ ...currentTool, input });
          currentTool = null;
          inputJson   = '';
        }
        break;
    }
  }

  // Capture the complete message (needed to preserve thinking blocks)
  const finalMsg = await stream.finalMessage();
  process.stdout.write('\n');

  // Append the full assistant turn to the conversation
  messages.push({ role: 'assistant', content: finalMsg.content });

  // If Claude used tools, execute them and loop
  if (toolCalls.length > 0) {
    const toolResults = [];

    for (const tool of toolCalls) {
      if (tool.name === 'run_command') {
        const { command, description } = tool.input;
        console.log(`\n  [Checking] ${description}`);
        console.log(`  > ${command}`);

        const result  = await runCommand(command);
        const preview = (result.stdout || result.stderr || '(no output)').slice(0, 300);
        console.log(`  ${preview.split('\n').join('\n  ')}`);

        toolResults.push({
          type:        'tool_result',
          tool_use_id: tool.id,
          content:     formatToolResult(result),
        });
      }
    }

    messages.push({ role: 'user', content: toolResults });
    return chat(messages);   // Continue after tool results
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CLI entry point
// ─────────────────────────────────────────────────────────────────────────────
async function main() {
  console.log('');
  console.log('╔══════════════════════════════════════════════════════════════╗');
  console.log('║   Master Electronics — Developer Environment Setup Guide     ║');
  console.log('╠══════════════════════════════════════════════════════════════╣');
  console.log('║  Before you start, you will need:                            ║');
  console.log('║    1. A GitHub account (free — we will help you create one)  ║');
  console.log('║    2. A Claude account (free — claude.ai — needed for        ║');
  console.log('║       Claude Code in Step 6)                                 ║');
  console.log('║                                                              ║');
  console.log('║  Type your messages and press Enter to continue.             ║');
  console.log('║  Type "quit" or close this window to exit at any time.       ║');
  console.log('╚══════════════════════════════════════════════════════════════╝');
  console.log('');

  const rl       = readline.createInterface({ input: process.stdin, output: process.stdout });
  const messages = [];

  // Start with Claude's greeting — kick off the conversation
  messages.push({
    role:    'user',
    content: "Hi! IT just finished setting up my computer and told me to run this setup guide. I'm ready to get started.",
  });

  try {
    await chat(messages);
  } catch (err) {
    console.error('\nError on startup:', err.message);
    process.exit(1);
  }

  // Main conversation loop
  const prompt = () => {
    rl.question('\nYou: ', async (raw) => {
      const input = raw.trim();

      if (!input) {
        prompt();
        return;
      }

      if (['quit', 'exit', 'bye', 'done'].includes(input.toLowerCase())) {
        console.log('\nGoodbye! Reach out to #it-support in Slack if you need any help.');
        rl.close();
        return;
      }

      messages.push({ role: 'user', content: input });

      try {
        await chat(messages);
      } catch (err) {
        console.error('\nError:', err.message);
        if (err.status === 401) {
          console.error('Authentication error — ask IT to check the ANTHROPIC_API_KEY configuration.');
        }
      }

      prompt();
    });
  };

  prompt();
}

main().catch((err) => {
  console.error('Fatal:', err);
  process.exit(1);
});
