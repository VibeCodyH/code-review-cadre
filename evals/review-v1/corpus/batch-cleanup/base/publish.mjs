export async function publish(files, storage) {
  const staged = [];
  try {
    for (const file of files) staged.push(await storage.stage(file));
    return await storage.commit(staged);
  } catch (error) {
    await Promise.all(staged.map(id => storage.remove(id)));
    throw error;
  }
}
