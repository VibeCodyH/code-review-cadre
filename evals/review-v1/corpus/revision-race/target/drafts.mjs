export async function updateDraft(store, id, expectedRevision, patch) {
  const current = await store.get(id);
  if (current.revision !== expectedRevision) return false;
  const fields = { title: patch.title };
  await store.put(id, { ...current, ...fields, revision: current.revision + 1 });
  return true;
}
