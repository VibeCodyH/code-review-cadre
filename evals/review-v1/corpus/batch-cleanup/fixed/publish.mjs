export async function publish(files, storage) {
  const outcomes = await Promise.allSettled(files.map(file => storage.stage(file)));
  const staged = outcomes.filter(result => result.status === 'fulfilled').map(result => result.value);
  try {
    const failure = outcomes.find(result => result.status === 'rejected');
    if (failure) throw failure.reason;
    return await storage.commit(staged);
  } catch (error) {
    await Promise.all(staged.map(id => storage.remove(id)));
    throw error;
  }
}
