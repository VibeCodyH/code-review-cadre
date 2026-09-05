export async function publish(files, storage) {
  let staged = [];
  try {
    staged = await Promise.all(files.map(file => storage.stage(file)));
    return await storage.commit(staged);
  } catch (error) {
    await Promise.all(staged.map(id => storage.remove(id)));
    throw error;
  }
}
