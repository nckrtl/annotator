# Agent prompts interpolate names and paths into shell and jq

- Severity: suggestion
- Area: security
- Location: `Sources/AnnotatorCore/Projects.swift:124`, `Sources/AnnotatorCore/Projects.swift:151`

## What is wrong

`AgentPrompt.make` builds a prompt the user pastes into an agent, and the same text is the first Conn turn (`Sources/Annotator/AppController.swift:511`). Project name, folder, notes, and the server URL are inserted raw:

```swift
filter = "select(.native.project == \"\(project.name)\")"
root = project.root.isEmpty ? "" : "PROJECT_ROOT='\(project.root)'\n"
// ...
ANNOTATIONS_URL='\(server)'
```

Notes are appended after the steps (`Sources/AnnotatorCore/Projects.swift:169`). A name that contains `"` changes the `jq` program. A folder or URL that contains `'` closes the shell string. The agent is told to run those commands.

Names and folders come from `routes.json` and from the Projects form. They are the user's data. They are still unquoted, so a normal folder such as `Nick's App` breaks the command, and a hostile or sloppy `routes.json` changes which records the filter selects.

## Why it matters

The copied prompt is the agent's procedure, including `claim` and `complete`. A broken quote makes it operate on the wrong set, or makes the shell run more than the `curl` the line shows. Notes are free text and are a reasonable place for a reminder. They should not be able to rewrite the `jq` filter by accident.

## What to change

Reject or escape `"` and `\` in the project name used inside `jq`. Shell-quote `ANNOTATIONS_URL` and `PROJECT_ROOT` with single quotes and the `'\''` rule. Put notes after a clear boundary and outside the command lines. Keep the filter as data, for example a `--arg` passed to `jq`, so the name cannot change the program.
