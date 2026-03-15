# ct watch → Cell Inspector Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Transform ct watch from a status list into a live cell debugger with detail pane, elapsed times, hard/soft distinction, progress bars, and search.

**Architecture:** Split-pane layout. Top = navigable cell list (existing). Bottom = detail pane showing cell body, givens, oracles, trace for the focused cell. Enhanced main query adds computing_since and assigned_piston. Detail pane uses separate queries triggered on cursor movement.

**Tech Stack:** Go, Bubble Tea v2, Lipgloss v2, Bubbles v2 (viewport), Dolt/MySQL

---

### Task 1: Enhance data model — computing_since, assigned_piston, body

**Files:**
- Modify: `cmd/ct/main.go` (watchCell struct, queryWatchData)

Add `computingSince *time.Time`, `assignedPiston string`, and `body string` to watchCell.
Update SQL query to select `c.computing_since, c.assigned_piston, c.body`.

### Task 2: Computing elapsed time in cell list

**Files:**
- Modify: `cmd/ct/main.go` (renderContent, navCell case)

When state is "computing" and computingSince is set, show elapsed duration
after the state label: `▶ cell-name  computing 2m34s`.

### Task 3: Hard/soft cell icons

**Files:**
- Modify: `cmd/ct/main.go` (renderContent, navCell case)

Soft cells: `◈` (computing), `◇` (declared). Hard cells keep `■/○`.
Both frozen and bottom keep `■` and `⊥` regardless of body_type.

### Task 4: Program progress bar

**Files:**
- Modify: `cmd/ct/main.go` (renderContent, navProgram case)

Replace `4/8 frozen` with `[████░░░░] 4/8` using lipgloss colors.
Green for frozen portion, dim for remaining.

### Task 5: Detail pane — data model and queries

**Files:**
- Modify: `cmd/ct/main.go` (new types, new query functions)

New types: `cellDetail` with body, bodyType, modelHint, givens, oracles, trace.
New query: `queryDetailData(db, cellID, progID)` runs 3 queries (givens, oracles, trace).
New message: `detailDataMsg`.

### Task 6: Detail pane — layout and rendering

**Files:**
- Modify: `cmd/ct/main.go` (watchModel, View, Update, WindowSizeMsg)

Add `detailVP viewport.Model` and `detail *cellDetail` to watchModel.
Split height: top viewport gets 2/3, detail viewport gets 1/3.
`d` key toggles detail pane on/off. Pane renders cell body, givens, oracles, trace.
On cursor movement, fire detailFetchCmd for the focused cell.

### Task 7: Search/filter

**Files:**
- Modify: `cmd/ct/main.go` (watchModel, Update, renderContent)

`/` enters filter mode. `filterText string` and `filtering bool` on model.
While filtering, typed characters append to filterText, esc exits.
navItems() filters cells whose name doesn't contain filterText.
Show filter bar in header when active.

---

Build and test after each task:
```bash
cd /home/nixos/gt/doltcell/crew/helix/cmd/ct && go build -o ../../ct .
RETORT_DSN="root@tcp(127.0.0.1:3307)/retort" ../../ct watch
```
