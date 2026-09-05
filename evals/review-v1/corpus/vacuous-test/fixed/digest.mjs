export async function sendDigest(recipients, deliver) {
  for (const recipient of recipients) {
    if (recipient.subscribed) await deliver(recipient.id);
  }
}
