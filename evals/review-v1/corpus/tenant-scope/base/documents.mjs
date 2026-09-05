export async function renameDocument(store, actor, id, title) {
  const document = await store.find({ id, tenantId: actor.tenantId });
  if (!document) throw new Error('Document not found');
  return store.save({ ...document, title });
}
