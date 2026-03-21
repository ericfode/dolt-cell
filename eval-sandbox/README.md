# Evaluation Sandbox — Substrate Bakeoff

This directory contains implementations of cell programs in four candidate
languages, evaluated to choose the cell computation substrate.

## Results

| Language | Rating | Verdict |
|----------|--------|---------|
| **Lua** | 4/5 | **WINNER** — loadstring+setfenv=eval, coroutines=stems, tables=everything |
| Jsonnet | 3/5 | Good constructors, but can't serialize functions |
| Starlark | 2/5 | No multiline strings, 4:1 boilerplate ratio |
| CUE | 2/5 | No user functions, schema language not computation |

## Canonical Implementation

The winning Lua implementation is at `examples/cell-zero.lua`.
See `lua/REPORT.md` for the full evaluation.

## Design Doc

`docs/plans/2026-03-21-lua-substrate-design.md`
