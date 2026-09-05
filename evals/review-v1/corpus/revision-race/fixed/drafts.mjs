export async function updateDraft(store, id, expectedRevision, patch) {
  const fields = { title: patch.title };
  return store.compareAndSwap(id, expectedRevision, fields);
}
