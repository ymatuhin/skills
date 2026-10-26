---
name: implement-spec
description: "Implement the result of /to-spec and /to-tickets in code."
disable-model-invocation: true
---

You have been provided a spec. This spec should have tickets associated with it, describing how to implement the spec.

The issue tracker should have been provided to you. If not, tell the user to run `/setup-matt-pocock-skills`.

The goal is the entire spec implemented on a single **integration branch**, with every ticket resolved the way the issue tracker closes work.

The tickets are not a list of steps. They are a **task graph** with blocking relationships between them. This means there is always a **frontier** of tickets which are ready to be grabbed.

## Sessions

Work runs in parallel **sessions** started with `mcp__ccd_session__start_session` (`initiation: "user_asked"`, `context: "fresh"`). Briefs are **context pointers** to the spec, tickets, research notes, and commits, not copies of them.

An **implementer session** gets exactly one ticket. Start it with `use_worktree: true` and `source_branch` set to the integration branch. Its brief: build the ticket with the `tdd` skill, commit, merge the integration branch tip into its branch, report the branch name.

## Steps

1. Read the spec and tickets to understand the task graph.

2. When two or more tickets need the same lookup, start one **exploration session** (`use_worktree: false`, cheaper `model`) that saves markdown notes outside the repo. Point implementers at the notes.

3. Create the integration branch. If the issue tracker closes work through PRs, or the user asks for one, open a draft PR after the first merge in step 5, marked as closing the spec and tickets.

4. Start implementer sessions for the whole frontier in one message.

5. When an implementer finishes, merge its branch into the integration branch yourself. On a conflict, abort and ask that session to merge the new tip again.

6. When the frontier grows, start implementers for the new tickets.

7. Once all tickets are merged, run the `code-review` skill on the integration branch and fix its findings in one implementer session.

8. If a draft PR exists, mark it ready for review. Otherwise, resolve each ticket the way the issue tracker closes work, and report the integration branch.

9. Archive the sessions, delete their branches and leftover worktrees.
