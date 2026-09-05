export async function updateDraft(store, id, expectedRevision, patch) {
  return store.compareAndSwap(id, expectedRevision, patch);
}
