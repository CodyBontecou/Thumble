import { CloudError } from '@tapping/cloud-contracts';

export function emailSignInEnabled(env) {
  return typeof env.EMAIL?.send === 'function' && typeof env.EMAIL_FROM === 'string' && /^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$/.test(env.EMAIL_FROM);
}

export async function sendSignInCode(env, { email, otp, type }) {
  if (!emailSignInEnabled(env) || type !== 'sign-in' || !/^\d{6}$/.test(otp)) throw new CloudError('not_configured', 'Email sign-in is unavailable.', 503);
  // Await the transport; Better Auth returns a generic request acknowledgement.
  // Codes stay in the recipient inbox and hashed verification storage, never logs.
  await env.EMAIL.send({
    from: { email: env.EMAIL_FROM, name: 'Thumble' }, to: email,
    subject: 'Your Thumble sign-in code',
    text: `Your Thumble sign-in code is ${otp}. It expires in 5 minutes and can be used once. If you did not request this code, you can ignore this email. Never share it with anyone.`,
    html: `<h1>Sign in to Thumble</h1><p>Your sign-in code:</p><p style="font-size:32px;letter-spacing:6px"><strong>${otp}</strong></p><p>It expires in 5 minutes and can be used once. If you did not request this code, you can ignore this email. Never share it with anyone.</p>`,
  });
}
