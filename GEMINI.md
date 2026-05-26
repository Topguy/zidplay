# Internal Notes for Antigravity

This file is a scratchpad/knowledge-base intended to keep track of project idiosyncrasies, system quirks, and language-specific rules.

## Zig Notes (0.16.0 specifics)
- **`std.ArrayList` changes**: In Zig 0.16.0, `std.ArrayList(T)` acts as an unmanaged list (previously `std.ArrayListUnmanaged`). 
  - Do NOT initialize with `std.ArrayList(T).init(allocator)`. This will fail with `struct 'array_list.Aligned(u32,null)' has no member named 'init'`.
  - Instead, initialize with `std.ArrayList(T).empty`.
  - When appending, explicitly pass the allocator: `list.append(allocator, item)`.
  - When freeing memory, explicitly pass the allocator: `list.deinit(allocator)`.

## System & Environment Notes
- **OS**: Windows
- **Shell**: PowerShell
- **Command Separators**: Do NOT use `&&` to chain commands in Windows PowerShell. Use `;` instead. For example: `git add . ; git commit -F msg.txt`.
- **Git Commits**: The user strictly requires using a temporary text file for git commits. 
  - Standard format: `git commit -F commit_msg.txt ; Remove-Item commit_msg.txt`.

## Build System
- `zig build` is used for compilation.
- The project wraps `libsidplayfp` and `libresidfp`.

*Do not place user-facing documentation here. Use `README.md` for that.*
