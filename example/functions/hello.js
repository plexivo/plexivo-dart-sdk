// A Plexivo Function the examples call. Deploy it from the database's
// Functions tab as `hello`. It runs beside your data, with the caller's
// identity in ctx: ctx.user is the signed-in user's claims, or null.
export default async (req, ctx) => {
  const url = new URL(req.url);
  const body = req.method === 'GET' ? {} : await req.json().catch(() => ({}));
  const name = body.name ?? url.searchParams.get('name') ?? 'there';
  return {
    message: `Hello, ${name}!`,
    signedIn: ctx.user != null,
    method: req.method
  };
};
