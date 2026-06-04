# gitcommitai.nvim

AI-powered Git commit message generation and formatting plugin for Neovim.

## Features

- **Use AI for commit generation**:
  Automatically generates conventional commit messages using AI (via [aichat](https://github.com/sigoden/aichat))
- **Conventional Commits**:
  Let you easily choose conventional commit types (feat, fix, docs, etc.)
- **Smart Formatting**:
  Automatic wrapping and reflowing of commit message body
- **AI Tool Trailers**:
  Add co-author and AI-assisted-by trailers
- **Subject Line Length Indicator**:
  Real-time visual feedback on subject line length
- **Smart Amend Detection**:
  Provide full context (original changes + new staged changes) when amending commits
- **Undo/Redo**:
  Restore previous commit messages like emacs's gitcommit.

## Requirements

- Neovim >= 0.9.0
- [aichat](https://github.com/sigoden/aichat) CLI tool
- Git with `git interpret-trailers` support

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "chmouel/gitcommitai.nvim",
  ft = "gitcommit",
  opts = {
    model = "gemini:gemini-3.1-flash-lite-preview",  -- aichat model to use
    role = "gitcommit",                       -- aichat role
  },
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "chmouel/gitcommitai.nvim",
  ft = "gitcommit",
  config = function()
    require("gitcommitai").setup({
      model = "gemini:gemini-3.1-flash-lite-preview",
      role = "gitcommit",
    })
  end,
}
```

### Using [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'chmouel/gitcommitai.nvim'

" In your init.vim or init.lua:
lua << EOF
require("gitcommitai").setup({
  model = "gemini:gemini-3.1-flash-lite-preview",
  role = "gitcommit",
})
EOF
```

## Configuration

Here's the default configuration:

```lua
require("gitcommitai").setup({
  -- AI model configuration
  model = "gemini:gemini-3.1-flash-lite-preview",
  role = "gitcommit",
  autocommit = true,  -- Auto-generate commit message on COMMIT_EDITMSG open

  -- Subject line length indicators
  subject_warn_length = 50,   -- Warning threshold (yellow)
  subject_error_length = 72,  -- Error threshold (red)

  -- Ticket extraction patterns from branch names
  ticket_patterns = {
    "(%a+%-%d%d%d+)",  -- letters-digits (3+ digits): JIRA-123, srvkp-9991
    "(%a+_%d%d%d+)",   -- letters_digits (3+ digits): JIRA_123
    "#(%d+)",          -- #123 (GitHub issues)
  },

  -- Jira configuration
  jira_base_url = "https://issues.redhat.com/browse",
  jira_uppercase = true,  -- Convert ticket to uppercase (jira-123 -> JIRA-123)

  -- Max characters to send to AI (prevents sending massive diffs like lockfiles)
  max_input_length = 64000,

  -- Message used when staged changes are whitespace-only after ignoring spaces
  whitespace_only_commit_message = {
    enabled = true,
    subject = "style: apply whitespace-only formatting",
    body = {
      "Normalize formatting in the staged files without changing code behavior.",
      "",
      "The staged diff is empty after ignoring whitespace, so this commit only updates",
      "spacing, indentation, or line wrapping.",
    },
    include_files = true,
    files_heading = "Affected files:",
    max_files = 20,
  },

  -- AI tool trailers
  trailers = {
    { name = "Claude",         line = "Co-Authored-By: Claude <noreply@anthropic.com>" },
    { name = "GitHub Copilot", line = "AI-assisted-by: GitHub Copilot" },
    { name = "Google Gemini",  line = "AI-assisted-by: Google Gemini" },
    { name = "OpenAI ChatGPT", line = "AI-assisted-by: OpenAI ChatGPT" },
    { name = "Cursor",         line = "AI-assisted-by: Cursor" },
  },

  -- Conventional commit types
  conventional_commits = {
    { type = "feat",     desc = "A new feature" },
    { type = "fix",      desc = "A bug fix" },
    { type = "docs",     desc = "Documentation only changes" },
    { type = "style",    desc = "Code style (formatting, semicolons, etc)" },
    { type = "refactor", desc = "Code change that neither fixes a bug nor adds a feature" },
    { type = "perf",     desc = "A code change that improves performance" },
    { type = "test",     desc = "Adding missing tests or correcting existing tests" },
    { type = "build",    desc = "Changes to build system or dependencies" },
    { type = "ci",       desc = "Changes to CI configuration" },
    { type = "chore",    desc = "Other changes that don't modify src or test files" },
    { type = "revert",   desc = "Reverts a previous commit" },
  },
})
```

You can also replace `whitespace_only_commit_message` with a function if you want
full control over the generated lines:

```lua
require("gitcommitai").setup({
  whitespace_only_commit_message = function(ctx)
    local lines = {
      "style: normalize formatting",
      "",
      ("Apply whitespace-only formatting updates across %d staged file(s)."):format(ctx.file_count),
      "",
      "Files:",
    }

    for _, file in ipairs(ctx.files) do
      lines[#lines + 1] = "- " .. file
    end

    return lines
  end,
})
```

## Keymaps

The plugin sets up the following keymaps in `COMMIT_EDITMSG` buffers:

| Keymap       | Description                          |
|-------------|--------------------------------------|
| `<leader>agr` | Regenerate commit message with AI    |
| `<leader>agh` | Generate commit with hint            |
| `<leader>agm` | Regenerate with selected AI model    |
| `<leader>agv` | Toggle inline verbose diff           |
| `<leader>agu` | Undo/restore previous message        |
| `<leader>agc` | Clear entire buffer                  |
| `<leader>agd` | Delete commit message body           |
| `<leader>agt` | Add ticket from branch name          |
| `<leader>agp` | Apply conventional commit type       |
| `<leader>aga` | Add AI or co-author trailer          |

## Usage

### Automatic Generation

When you run `git commit`, the plugin automatically generates a commit message if the buffer is empty.
Set `autocommit = false` to disable this behavior and use manual keymaps only.

### Manual Regeneration

Press `<leader>agr` to regenerate the commit message while preserving trailers.

### Generating with a Hint

Press `<leader>agh` to regenerate the commit message with a specific focus or context:

1. Press `<leader>agh`
2. Enter a hint describing what to emphasize (e.g., "focus on the API changes", "this is a breaking change", "mention the performance improvement")
3. The AI will generate a commit message that incorporates your hint

This is useful when you want to guide the AI to emphasize specific aspects of your changes.

### Regenerating with Another Model

Press `<leader>agm` to regenerate using a one-off model selection:

1. Press `<leader>agm`
2. Pick a model from `aichat --list-models`
3. The commit message is regenerated with the selected model (without changing your default `model` config)

### Inline Verbose Diff

Press `<leader>agv` to toggle a commented staged diff preview inline in the
commit buffer, similar to the context shown by `git commit -v`. The preview is
commented out so it will not become part of the commit message.

### Adding Conventional Commit Type

1. Press `<leader>agp`
2. Select the commit type (feat, fix, docs, etc.)
3. Optionally enter a scope
4. The subject line will be prefixed with the conventional commit format

### Adding Ticket References

Press `<leader>agt` to automatically extract and add a ticket reference from your branch name:

- Branch: `feature/JIRA-1234-add-feature` → Adds `Jira: https://issues.redhat.com/browse/JIRA-1234`
- Branch: `fix/#123-bug-fix` → Adds `Fixes: #123`

### Adding AI Trailers

Press `<leader>aga` to select and add an AI tool trailer to acknowledge AI assistance.

### Subject Line Length Indicator

The plugin displays a real-time indicator showing the character count of your subject line:

- Gray (hint): Within recommended length (≤50 chars)
- Yellow (warning): Between 50-72 chars
- Red (error): Over 72 chars

## aichat Configuration

This plugin requires [aichat](https://github.com/sigoden/aichat) with a configured role for commit message generation.

Example `~/.config/aichat/roles.yaml` entry:

```yaml
- name: gitcommit
  prompt: >
    You are a git commit message generator. Generate a clear, concise conventional
    commit message based on the git diff and status provided. Follow these rules:

    1. Subject line: max 50 chars (hard limit 72), imperative mood, no period
    2. Format: type(scope): description
    3. Types: feat, fix, docs, style, refactor, perf, test, build, ci, chore
    4. Body: wrap at 72 chars, explain what and why (not how)
    5. Use bullet points with - or * for lists
    6. Separate subject from body with blank line
    7. Do NOT add trailers (Signed-off-by, Co-authored-by, etc)

    Input format:
    - Lines starting with # are git comments (status, diff summary)
    - git diff output shows the actual changes

    Output only the commit message, nothing else.
```

## Tips

1. **Customize AI Model**: Change the `model` option to use different AI providers supported by aichat (OpenAI, Claude, Gemini, etc.). Use a smaller model for faster responses like `gemini:gemini-3.1-flash-lite-preview`
2. **Ticket Patterns**: Adjust `ticket_patterns` to match your team's branch naming conventions
3. **Jira URL**: Set `jira_base_url` to your organization's Jira instance
4. **Custom Trailers**: Add your own AI tools or co-authors to the `trailers` list

## How It Works

1. **Automatic Detection**: On opening `COMMIT_EDITMSG`, the plugin checks if there's existing content
2. **AI Generation**: If empty, it sends the git diff and status to aichat for message generation
3. **Smart Formatting**: The plugin automatically wraps text at 72 characters while preserving:
   - List item formatting (bullets and numbers)
   - Indentation
   - Hard line breaks (lines ending with double spaces)
4. **Trailer Management**: Git trailers are preserved when regenerating or editing messages
5. **Amend Strategy**: When amending a commit (`git commit --amend`), the plugin detects this state and:
   - Fetches the diff relative to the *parent* of the current commit (HEAD^) to capture the full context of the change.
   - Includes the existing commit message in the prompt.
   - Instructs the AI to generate a new message based on the combined context.

## License

Apache License 2.0

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
