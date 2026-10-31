# Laplace cleanup evidence

This archive preserves source reconciliation and cleanup receipts, including their
individual timestamps and scope. It does not change runtime source on main.
Only a passed platform-final-receipt.json would assert complete platform delivery.
Windows approval, installation, and access repair may still be pending in earlier
snapshots. Generated caches and recovery ZIPs remain local retained artifacts;
their receipt hashes are recorded here, not their complete payloads.

The required floor contains all 1,114,112 codepoints, including the 2,048
surrogates. Removing them was a regression; restoring that floor and preserving
their generalized UTF-8 identities is part of the implementation on main.
Historical archive labels do not supersede the corrected implementation.

Historical one-off tools document operations already taken or prepared. They are
not a supported command interface and must not be blindly rerun.
