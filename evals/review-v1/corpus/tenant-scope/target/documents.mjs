async function loadDocument(store, id) {
  const document = await store.find({ id });
  if (!document) throw new Error('Document not found');
  return document;
}

export async function renameDocument(store, actor, id, title) {
  const document = await loadDocument(store, id);
  return store.save({ ...document, title: title.trim() });
}
