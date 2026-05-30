---
name: review-prd-external
description: Use when a PRD document is ready and needs external review - generates a review prompt for manual use in other models (ChatGPT, Gemini, etc.)
user_invocable: true
---

# External PRD Review (Manual)

Generate a static review prompt for PRD and output it for the user to copy-paste.

**Announce at start:** "Using review-prd-external skill to generate a PRD review prompt."

## Process

### Step 1: Verify PRD Exists

Check that `.taskmaster/docs/prd.md` exists. If not — stop and tell the user to generate PRD first.

### Step 2: Output the Prompt

Output the following prompt verbatim inside a fenced code block. Do NOT modify the template. Do NOT collect context, do NOT read the PRD, do NOT substitute anything.

Intro line before the code block: "Вот prompt для ревью PRD. Скопируйте и вставьте в нужную модель."

```
## TASK

Review and critique the PRD (Product Requirements Document).

You have full access to the project. Read the PRD and explore the codebase as needed to understand the context.

**IMPORTANT: Respond in Russian language.**

## DOCUMENT

PRD: `.taskmaster/docs/prd.md`

Read the document before reviewing.

## REVIEW FOCUS

Critique the PRD on:

1. **Completeness** — are all sections present and sufficiently detailed? Are there gaps in requirements, missing edge cases, or undefined behaviors?

2. **Requirements Quality** — are functional requirements specific, measurable, and testable? Are priorities (Must/Should/Could) assigned correctly? Are acceptance criteria clear and verifiable?

3. **User Stories** — are they well-formed (role/action/benefit)? Do acceptance criteria cover happy path, edge cases, and error scenarios? Are all user types represented?

4. **Non-Functional Requirements** — are performance, security, scalability targets specific (numbers, not adjectives)? Are they realistic and measurable?

5. **Task Decomposition** — are implementation tasks right-sized (one focused session each)? Are dependencies correct and complete? Is the phase ordering logical? Are complexity estimates reasonable?

6. **Scope & Feasibility** — is MVP properly bounded? Are "out of scope" items explicit? Are technical constraints realistic? Is the overall scope achievable given stated team/timeline?

7. **Risks & Open Questions** — are key risks identified? Are mitigations proposed? Are open questions actionable with clear owners and deadlines?

8. **Internal Consistency** — do requirements align with user stories? Does the roadmap cover all requirements? Do task dependencies match requirement dependencies?

Be critical. Point out problems, not just praise.

## OUTPUT FORMAT

### Critical Issues
[Problems that MUST be addressed before implementation — ambiguous requirements, missing critical functionality, contradictions, unrealistic targets]

### Concerns
[Potential problems worth discussing — possible scope creep, risky assumptions, weak acceptance criteria]

### Suggestions
[Improvements — better task breakdown, additional requirements to consider, clearer success metrics]

### Missing
[Sections or details that are absent but should be present — missing user types, unaddressed edge cases, absent NFRs]

### Questions
[Clarifications needed from the PRD author]
```
