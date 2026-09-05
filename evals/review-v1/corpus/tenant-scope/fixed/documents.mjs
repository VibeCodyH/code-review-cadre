async function loadDocument(store, actor, id) {
  const document = await store.find({ id, tenantId: actor.tenantId });
  if (!document) throw new Error('Document not found');
  return document;
}

export async function renameDocument(store, actor, id, title) {
  const document = await loadDocument(store, actor, id);
  return store.save({ ...document, title: title.trim() });
}
