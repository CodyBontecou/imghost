// Compatibility entry point for links sent before reset emails used native codes.
// GET is read-only: mail scanners must never consume a password-reset challenge.
export function handlePasswordResetPage(request: Request): Response {
  const token = new URL(request.url).searchParams.get('token') || '';
  const escaped = token.slice(0, 512).replace(/[&<>"']/g, character => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  })[character]!);

  return new Response(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>imghost password reset</title></head>
<body><main><h1>Reset your imghost password</h1>
<p>Open imghost on iOS or macOS. Return to the Forgot Password screen and choose Enter Code.</p>
${token ? `<p>Copy the entire code below into the Reset Code field:</p><pre>${escaped}</pre>` : '<p>Request a reset code in the app and copy it from your email.</p>'}
<p>Enter and confirm a new password of at least 8 characters, then sign in with the same email address. This works for accounts created with Sign in with Apple too.</p>
<p>Codes expire 1 hour after being requested and work only once. If the app rejects this code, request a new one. Never share your code.</p>
</main></body></html>`, {
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-store',
      'Referrer-Policy': 'no-referrer',
      'Content-Security-Policy': "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      'X-Content-Type-Options': 'nosniff',
      'X-Robots-Tag': 'noindex, nofollow',
    },
  });
}
