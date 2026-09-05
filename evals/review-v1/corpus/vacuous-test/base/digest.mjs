export async function sendDigest(recipients, deliver) {
  for (const recipient of recipients) await deliver(recipient.id);
}
