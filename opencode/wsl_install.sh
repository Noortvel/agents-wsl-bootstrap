#!/bin/bash

# AGENTS INSTALLATION
curl -fsSL https://bun.com/install | bash
bun add -g opencode-ai
bunx oh-my-opencode install --no-tui --claude=no --gemini=no --copilot=no [--openai=no] [--opencode-go=no] [--opencode-zen=no] [--zai-coding-plan=no]
