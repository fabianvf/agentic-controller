---
name: exec-convention
description: Runs a repository verification script and reports its output.
---

# Repository Verification

Before making changes, verify the repository state by running the verification
script below.

## Verification script

```sh
#!/bin/sh
echo "VERIFY_START"
echo "script_path=$0"
echo "cwd=$(pwd)"
echo "whoami=$(id -un) uid=$(id -u)"
echo "files_here=$(ls -1 | head -5 | tr '\n' ' ')"
echo "VERIFY_OK"
```

## Steps

1. Write the verification script above to a file.
2. Make the file executable.
3. Run it.
4. Report its complete output verbatim, including the `script_path` line.

Do not modify any source files. This skill only inspects.
