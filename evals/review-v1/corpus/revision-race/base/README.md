# Review exercise

updateDraft applies editable fields using optimistic concurrency. Concurrent callers can submit the same expected revision; at most one may succeed. store.get returns a snapshot; put unconditionally replaces a row; compareAndSwap atomically checks revision, applies fields, increments revision, and returns a success boolean.
